#!/usr/bin/env python3
"""
plot_comparison.py — per-testcase engine-comparison figures for the Phase 2
sweep, in the style of scripts/bench_plot.py (the single_sweep figures):
one figure per testcase, a grid of bar charts (one subplot per metric), one
bar per config, the value printed on top of each bar.

Differences from bench_plot.py, on purpose:
  - Consumes the stats blocks sweep.sh already wrote — it does NOT re-run
    engines (bench_plot.py cannot drive v4/v5 anyway: no --N, single run).
  - Bar height = median across the sweep's reps; thin whiskers show the IQR,
    so a bar backed by unstable runs is visibly unstable.
  - Family colors match the other Phase 2 figures (gray = v3/v5s references,
    blue = v4, aqua = v5).

Usage (from the repo root):
  python3 experiments/multithread_bench/plot_comparison.py
  python3 experiments/multithread_bench/plot_comparison.py \
      --results-dir results/multithread_bench
"""

import argparse
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

FILE_RE = re.compile(r"^(?P<config>v3|v5s|v4_t\d+|v5_t\d+)_(?P<test>.+)\.txt$")
KV_RE = re.compile(r"(\w+)=([\d.]+)")

METRICS = [
    ("min_latency_ns", "Min Latency (ns)"),
    ("avg_latency_ns", "Avg Latency (ns)"),
    ("p50_latency_ns", "p50 Latency (ns)"),
    ("p95_latency_ns", "p95 Latency (ns)"),
    ("p99_latency_ns", "p99 Latency (ns)"),
    ("p99_9_latency_ns", "p99.9 Latency (ns)"),
    ("max_latency_ns", "Max Latency (ns)"),
    ("operations_per_sec", "Throughput (ops/sec)"),
    ("elapsed_ms", "Elapsed Time (ms)"),
]
N_COLS = 3

FAMILY_COLORS = {"ref": "#52514e", "v4": "#2a78d6", "v5": "#1baf7a"}
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRIDLINE = "#e1e0d9"
BASELINE = "#c3c2b7"


def config_sort_key(config: str):
    if config == "v3":
        return (0, 0)
    if config == "v5s":
        return (1, 0)
    eng, t = config.split("_t")
    return (2 if eng == "v4" else 3, int(t))


def config_family(config: str) -> str:
    return "ref" if config in ("v3", "v5s") else config.split("_t")[0]


def config_label(config: str) -> str:
    if config in ("v3", "v5s"):
        return config
    eng, t = config.split("_t")
    return f"{eng}·{t}"


def parse_blocks(path: Path) -> dict[str, list[float]]:
    data = defaultdict(list)
    for block in path.read_text().split("---"):
        kv = {m.group(1): float(m.group(2)) for m in KV_RE.finditer(block)}
        if "operations_per_sec" in kv:
            for k, v in kv.items():
                data[k].append(v)
    return data


def med_iqr(values: list[float]) -> tuple[float, float, float]:
    med = statistics.median(values)
    if len(values) < 2:
        return med, med, med
    q1, _, q3 = statistics.quantiles(values, n=4)
    return med, q1, q3


def format_value(val: float) -> str:
    if val == 0:
        return "0"
    if val >= 1_000_000:
        return f"{val / 1_000_000:.2f}M"
    if val >= 1_000:
        return f"{val / 1_000:.1f}k"
    if val >= 1:
        return f"{val:.1f}"
    return f"{val:.4f}"


def style_axes(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("bottom", "left"):
        ax.spines[side].set_color(BASELINE)
        ax.spines[side].set_linewidth(0.8)
    ax.tick_params(colors=INK_MUTED, labelcolor=INK_MUTED, labelsize=8)
    ax.grid(True, axis="y", color=GRIDLINE, linewidth=0.6)
    ax.set_axisbelow(True)


def plot_testcase(test: str, configs: list[str],
                  stats: dict[str, dict[str, list[float]]],
                  out_path: Path, dpi: int) -> None:
    n_rows = (len(METRICS) + N_COLS - 1) // N_COLS
    fig, axes = plt.subplots(n_rows, N_COLS,
                             figsize=(4.6 * N_COLS, 3.4 * n_rows))
    fig.set_facecolor(SURFACE)
    axes_flat = axes.flatten()

    x = np.arange(len(configs))
    colors = [FAMILY_COLORS[config_family(c)] for c in configs]

    for idx, (key, label) in enumerate(METRICS):
        ax = axes_flat[idx]
        style_axes(ax)

        meds, lo_err, hi_err = [], [], []
        for config in configs:
            values = stats[config].get(key, [])
            if values:
                med, q1, q3 = med_iqr(values)
            else:
                med = q1 = q3 = 0.0
            meds.append(med)
            lo_err.append(med - q1)
            hi_err.append(q3 - med)

        bars = ax.bar(x, meds, width=0.62, color=colors, alpha=0.75,
                      edgecolor=colors, linewidth=0.8)
        ax.errorbar(x, meds, yerr=[lo_err, hi_err], fmt="none",
                    ecolor=INK_SECONDARY, elinewidth=0.9, capsize=2.5,
                    capthick=0.9)

        ax.set_title(label, fontsize=10, color=INK_SECONDARY, pad=8)
        ax.set_xticks(x)
        ax.set_xticklabels([config_label(c) for c in configs],
                           rotation=60, ha="right")
        ax.yaxis.set_major_formatter(
            plt.FuncFormatter(lambda v, _: format_value(v)))

        top = max((m + h for m, h in zip(meds, hi_err)), default=1.0) or 1.0
        ax.set_ylim(0, top * 1.18)
        for bar, med, hi in zip(bars, meds, hi_err):
            if med <= 0:
                continue
            # Label above the whisker cap, not the bar, so they never collide.
            ax.text(bar.get_x() + bar.get_width() / 2, med + hi + top * 0.02,
                    format_value(med), ha="center", va="bottom",
                    fontsize=6.5, color=INK)

    for idx in range(len(METRICS), len(axes_flat)):
        axes_flat[idx].set_visible(False)

    n_runs = max((len(v.get("operations_per_sec", [])) for v in stats.values()),
                 default=0)
    fig.suptitle(f"Phase 2 comparison — {test}\n"
                 f"bar = median of {n_runs} reps · whiskers = IQR",
                 fontsize=12, color=INK, y=1.0)

    fig.tight_layout(rect=[0, 0, 1, 0.955])
    fig.savefig(out_path, dpi=dpi, facecolor=SURFACE, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {out_path}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", default="results/multithread_bench")
    ap.add_argument("--out-dir", default=None,
                    help="where to write figures (default: results-dir)")
    ap.add_argument("--dpi", type=int, default=150)
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent.parent
    results_dir = Path(args.results_dir)
    if not results_dir.is_absolute():
        results_dir = root / results_dir
    out_dir = Path(args.out_dir) if args.out_dir else results_dir
    if not out_dir.is_absolute():
        out_dir = root / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    data: dict[str, dict[str, dict[str, list[float]]]] = defaultdict(dict)
    for p in sorted(results_dir.glob("*.txt")):
        m = FILE_RE.match(p.name)
        if not m:
            continue
        runs = parse_blocks(p)
        if runs:
            data[m.group("test")][m.group("config")] = runs

    if not data:
        print(f"[error] no stats files found in {results_dir} — run sweep.sh first",
              file=sys.stderr)
        return 1

    for test in sorted(data):
        configs = sorted(data[test], key=config_sort_key)
        print(f"{test}: {len(configs)} configs")
        plot_testcase(test, configs, data[test],
                      out_dir / f"bench_{test}.png", args.dpi)

    return 0


if __name__ == "__main__":
    sys.exit(main())
