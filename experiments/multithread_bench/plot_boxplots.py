#!/usr/bin/env python3
"""
plot_boxplots.py — decision-table boxplots for the Phase 2 sweep, in the style
of bench_stability/plot_exp1.py.

Layout:
  rows    = testcases
  columns = throughput | p50 | p99 | p99.9 | max
  each cell: one box per config (v3, v5s, v4@t…, v5@t…), one point per rep.

Color groups the family, position+label carry identity:
  ink-gray = single-threaded references (v3, v5s)
  blue     = v4 (coarse global lock)
  aqua     = v5 (fine-grained per-level locks)

Latency columns use a log y-axis — cross-config spread under contention is
orders of magnitude, which a linear axis would crush. Throughput is linear
from 0.

Usage (from the repo root):
  python3 experiments/multithread_bench/plot_boxplots.py
  python3 experiments/multithread_bench/plot_boxplots.py \
      --results-dir results/multithread_bench
"""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
import numpy as np

FILE_RE = re.compile(r"^(?P<config>v3|v5s|v4_t\d+|v5_t\d+)_(?P<test>.+)\.txt$")
KV_RE = re.compile(r"(\w+)=([\d.]+)")

# (metric_key, column_label, scale, log_axis)
METRICS = [
    ("operations_per_sec", "throughput (Mops/s)", 1e-6, False),
    ("p50_latency_ns", "p50 (ns)", 1.0, True),
    ("p99_latency_ns", "p99 (ns)", 1.0, True),
    ("p99_9_latency_ns", "p99.9 (ns)", 1.0, True),
    ("max_latency_ns", "max (µs)", 1e-3, True),
]

# ── palette (dataviz reference instance, light mode) ────────────────────────
FAMILY_COLORS = {
    "ref": "#52514e",   # secondary ink — the single-threaded references
    "v4": "#2a78d6",    # categorical slot 1 (blue)
    "v5": "#1baf7a",    # categorical slot 2 (aqua)
}
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRIDLINE = "#e1e0d9"
BASELINE = "#c3c2b7"
ALPHA_BOX = 0.55


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


def draw_box(ax, pos, values, color):
    bp = ax.boxplot([values], positions=[pos], widths=0.62, patch_artist=True,
                    flierprops=dict(marker="o", markersize=2.5,
                                    markerfacecolor=INK_MUTED,
                                    markeredgecolor="none"),
                    medianprops=dict(color=color, linewidth=1.6),
                    whiskerprops=dict(color=color, linewidth=0.9),
                    capprops=dict(color=color, linewidth=0.9),
                    boxprops=dict(linewidth=0.9))
    for patch in bp["boxes"]:
        patch.set_facecolor(color)
        patch.set_alpha(ALPHA_BOX)
        patch.set_edgecolor(color)


def style_axes(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("bottom", "left"):
        ax.spines[side].set_color(BASELINE)
        ax.spines[side].set_linewidth(0.8)
    ax.tick_params(colors=INK_MUTED, labelcolor=INK_MUTED, labelsize=8,
                   which="both")
    ax.grid(True, axis="y", which="major", color=GRIDLINE, linewidth=0.6)
    ax.set_axisbelow(True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", default="results/multithread_bench")
    ap.add_argument("--out", default=None,
                    help="output image path (default: <results-dir>/boxplots.png)")
    ap.add_argument("--dpi", type=int, default=150)
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent.parent
    results_dir = Path(args.results_dir)
    if not results_dir.is_absolute():
        results_dir = root / results_dir
    out = Path(args.out) if args.out else results_dir / "boxplots.png"

    # (testcase, config) → {metric: [per-run values]}
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

    tests = sorted(data)
    configs = sorted({c for t in data.values() for c in t}, key=config_sort_key)
    positions = np.arange(len(configs), dtype=float)

    n_rows, n_cols = len(tests), len(METRICS)
    fig, axes = plt.subplots(n_rows, n_cols,
                             figsize=(3.2 * n_cols, 2.6 * n_rows + 0.8),
                             squeeze=False)
    fig.set_facecolor(SURFACE)

    for r, test in enumerate(tests):
        for c, (key, label, scale, log_axis) in enumerate(METRICS):
            ax = axes[r][c]
            style_axes(ax)

            for pos, config in zip(positions, configs):
                runs = data[test].get(config)
                if not runs or key not in runs:
                    continue
                values = [v * scale for v in runs[key]]
                draw_box(ax, pos, values, FAMILY_COLORS[config_family(config)])

            if log_axis:
                ax.set_yscale("log")
            else:
                ax.set_ylim(bottom=0)

            ax.set_xlim(positions[0] - 0.7, positions[-1] + 0.7)
            ax.set_xticks(positions)
            if r == n_rows - 1:
                ax.set_xticklabels([config_label(cfg) for cfg in configs],
                                   rotation=60, ha="right")
            else:
                ax.set_xticklabels([])

            if r == 0:
                ax.set_title(label, color=INK_SECONDARY, fontsize=10, pad=8)
            if c == 0:
                ax.set_ylabel(test, color=INK, fontsize=9.5)

    handles = [
        mpatches.Patch(facecolor=FAMILY_COLORS["ref"], alpha=ALPHA_BOX,
                       edgecolor=FAMILY_COLORS["ref"],
                       label="single-threaded reference (v3 / v5s)"),
        mpatches.Patch(facecolor=FAMILY_COLORS["v4"], alpha=ALPHA_BOX,
                       edgecolor=FAMILY_COLORS["v4"],
                       label="v4 — coarse global lock"),
        mpatches.Patch(facecolor=FAMILY_COLORS["v5"], alpha=ALPHA_BOX,
                       edgecolor=FAMILY_COLORS["v5"],
                       label="v5 — fine-grained per-level locks"),
    ]
    fig.legend(handles=handles, loc="lower center", ncol=3, frameon=False,
               fontsize=9, labelcolor=INK_SECONDARY,
               bbox_to_anchor=(0.5, 0.0))
    fig.suptitle("Phase 2 run matrix — per-rep distribution across "
                 "benchmark runs (one point per rep)",
                 color=INK, fontsize=12, x=0.02, ha="left")

    fig.tight_layout(rect=[0, 0.035, 1, 0.965])
    fig.savefig(out, dpi=args.dpi, facecolor=SURFACE, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
