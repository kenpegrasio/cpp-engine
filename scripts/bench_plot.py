#!/usr/bin/env python3
"""
Benchmark multiple matching engines across all test cases.
Produces one figure per test case; each figure has one bar-plot per metric
with one bar per engine so engines are directly comparable.

Usage:
    python bench_plot.py ./engine_v1 ./engine_v2
    python bench_plot.py ./engine_v1 ./engine_v2 ./engine_v3
    python bench_plot.py ./engine_v1 ./engine_v2 --test-dir tests/generated
    python bench_plot.py ./engine_v1 ./engine_v2 --tests tests/generated/heavy_overlap_mixed.txt
    python bench_plot.py ./engine_v1 ./engine_v2 --output-dir results/
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


METRICS = [
    ("avg_latency_ns",    "Avg Latency (ns)"),
    ("p50_latency_ns",    "p50 Latency (ns)"),
    ("p95_latency_ns",    "p95 Latency (ns)"),
    ("p99_latency_ns",    "p99 Latency (ns)"),
    ("p99_9_latency_ns",  "p99.9 Latency (ns)"),
    ("max_latency_ns",    "Max Latency (ns)"),
    ("operations_per_sec","Throughput (ops/sec)"),
    ("elapsed_ms",        "Elapsed Time (ms)"),
    ("transactions",      "Transactions"),
]

N_COLS = 3


def parse_benchmark_stderr(stderr_text: str) -> dict[str, float]:
    stats: dict[str, float] = {}
    for line in stderr_text.strip().splitlines():
        line = line.strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        try:
            stats[key.strip()] = float(value.strip())
        except ValueError:
            pass
    return stats


def run_benchmark(engine: str, test_file: Path) -> dict[str, float] | None:
    try:
        with open(test_file, "r") as f:
            result = subprocess.run(
                [engine, "--benchmark"],
                stdin=f,
                capture_output=True,
                text=True,
                timeout=120,
            )
    except FileNotFoundError:
        print(f"[error] engine not found: {engine}", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(f"[warn] timed out — {engine} on {test_file.name}", file=sys.stderr)
        return None

    if result.returncode != 0:
        print(
            f"[warn] exit {result.returncode} — {engine} on {test_file.name}",
            file=sys.stderr,
        )
        return None

    stats = parse_benchmark_stderr(result.stderr)
    if not stats:
        print(
            f"[warn] no benchmark output — {engine} on {test_file.name}",
            file=sys.stderr,
        )
        return None

    return stats


def format_value(val: float) -> str:
    if val >= 1_000_000:
        return f"{val / 1_000_000:.2f}M"
    if val >= 1_000:
        return f"{val / 1_000:.1f}k"
    if val >= 1:
        return f"{val:.1f}"
    return f"{val:.4f}"


def plot_testcase(
    test_name: str,
    engine_names: list[str],
    engine_stats: list[dict[str, float]],
    output_path: str,
) -> None:
    """One figure: subplots = metrics, bars within each subplot = engines."""
    n_engines = len(engine_names)
    n_rows = (len(METRICS) + N_COLS - 1) // N_COLS

    fig, axes = plt.subplots(n_rows, N_COLS, figsize=(6 * N_COLS, 5 * n_rows))
    axes_flat = axes.flatten()

    cmap = plt.get_cmap("tab10")
    colors = [cmap(i % 10) for i in range(n_engines)]
    x = np.arange(n_engines)
    bar_width = min(0.6, 0.8 / max(n_engines, 1))

    for idx, (metric_key, metric_label) in enumerate(METRICS):
        ax = axes_flat[idx]
        values = [stats.get(metric_key, 0.0) for stats in engine_stats]

        bars = ax.bar(
            x, values,
            width=bar_width,
            color=colors,
            edgecolor="white",
            linewidth=0.5,
        )

        ax.set_title(metric_label, fontsize=11, fontweight="bold", pad=8)
        ax.set_xticks(x)
        ax.set_xticklabels(engine_names, fontsize=9, ha="center")
        ax.set_ylabel(metric_label, fontsize=9)
        ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: format_value(v)))
        ax.grid(axis="y", linestyle="--", alpha=0.4)
        ax.set_axisbelow(True)

        for bar, val in zip(bars, values):
            height = bar.get_height()
            if height <= 0:
                continue
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                height * 1.01,
                format_value(val),
                ha="center",
                va="bottom",
                fontsize=7,
                color="#222222",
            )

    for idx in range(len(METRICS), len(axes_flat)):
        axes_flat[idx].set_visible(False)

    fig.suptitle(
        f"Benchmark — {test_name}",
        fontsize=14,
        fontweight="bold",
        y=1.01,
    )
    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved: {output_path}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Benchmark multiple matching engines and produce one comparison figure "
            "per test case."
        )
    )
    parser.add_argument(
        "engines",
        nargs="+",
        metavar="ENGINE",
        help="One or more engine executables to benchmark (e.g. ./engine_v1 ./engine_v2)",
    )
    parser.add_argument(
        "--test-dir",
        default="tests/generated",
        help="Directory containing test-case .txt files (default: tests/generated)",
    )
    parser.add_argument(
        "--tests",
        nargs="+",
        metavar="FILE",
        help="Specific test files to run instead of all files in --test-dir",
    )
    parser.add_argument(
        "--output-dir",
        default="diagrams",
        metavar="DIR",
        help="Directory to write output PNGs into (default: diagrams)",
    )
    args = parser.parse_args()

    # Resolve test files
    if args.tests:
        test_files = [Path(t) for t in args.tests]
    else:
        test_dir = Path(args.test_dir)
        if not test_dir.is_dir():
            print(f"[error] test directory not found: {test_dir}", file=sys.stderr)
            return 1
        test_files = sorted(test_dir.glob("*.txt"))

    if not test_files:
        print("[error] no test files found", file=sys.stderr)
        return 1

    engine_names = [os.path.basename(e) for e in args.engines]
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    any_success = False

    for test_file in test_files:
        print(f"\n[{test_file.stem}]")

        per_engine_stats: list[dict[str, float]] = []
        valid_engine_names: list[str] = []

        for engine, name in zip(args.engines, engine_names):
            print(f"  running {name} ...", end=" ", flush=True)
            stats = run_benchmark(engine, test_file)
            if stats is not None:
                per_engine_stats.append(stats)
                valid_engine_names.append(name)
                print("ok")
            else:
                print("failed")

        if not per_engine_stats:
            print(f"  [skip] all engines failed on {test_file.name}")
            continue

        any_success = True
        out_path = output_dir / f"bench_{test_file.stem}.png"
        plot_testcase(test_file.stem, valid_engine_names, per_engine_stats, str(out_path))

    if not any_success:
        print("[error] all benchmarks failed — nothing to plot", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
