#!/usr/bin/env python3
"""
Experiment 1 — Reproducibility: Ubuntu vs WSL box-plot comparison.

Layout (vertical):
  rows    = workloads  (5)
  columns = metrics    (min | p50 | p99 | p99.9 | max)
  each cell: grouped box plots  v1 / v2 / v3  ×  ubuntu (blue) / wsl (orange)

  - Metric labels sit at the BOTTOM of each cell (xlabel) so median
    annotations at the top don't collide with them.
  - Column headers are also stamped at the TOP of row-0 cells only
    as a visual anchor.
  - max is shown in µs (÷1000) to keep y-axis numbers readable.

Run from the repo root:
  python3 scripts/plot_exp1.py
"""

import re
from pathlib import Path
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

# ── paths ──────────────────────────────────────────────────────────────────
RESULTS    = Path(__file__).parent.parent.parent / "results"
UBUNTU_DIR = RESULTS / "phase_1_ubuntu"
WSL_DIR    = RESULTS / "phase_1_wsl"
OUT_FILE   = RESULTS / "exp1_boxplots.png"

ENGINES   = ["v1", "v2", "v3"]
WORKLOADS = ["all_buy", "all_sell", "heavy_overlap_mixed",
             "unmatched_mixed", "wide_range_mixed"]

# (metric_key, column_label, scale_factor, y_unit)
# scale_factor: multiply raw ns value before plotting
METRICS = [
    ("min_latency_ns",   "min",    1.0,        "ns"),
    ("p50_latency_ns",   "p50",    1.0,        "ns"),
    ("p99_latency_ns",   "p99",    1.0,        "ns"),
    ("p99_9_latency_ns", "p99.9",  1.0,        "ns"),
    ("max_latency_ns",   "max",    1e-3,       "µs"),   # ns → µs
]

COLORS = {
    "ubuntu": "#2196F3",   # blue
    "wsl":    "#FF9800",   # orange
}
ALPHA_BOX = 0.60

# ── parser ─────────────────────────────────────────────────────────────────
def parse_file(path: Path) -> dict[str, list[float]]:
    text = path.read_text()
    runs = [blk.strip() for blk in text.split("---") if blk.strip()]
    data: dict[str, list[float]] = defaultdict(list)
    for run in runs:
        for line in run.splitlines():
            m = re.match(r"(\w+)=([\d.]+)", line.strip())
            if m:
                data[m.group(1)].append(float(m.group(2)))
    return data


def load_all() -> dict:
    result = {"ubuntu": {}, "wsl": {}}
    for env, folder in [("ubuntu", UBUNTU_DIR), ("wsl", WSL_DIR)]:
        for engine in ENGINES:
            result[env][engine] = {}
            for wl in WORKLOADS:
                fname = folder / f"{engine}_{wl}.txt"
                result[env][engine][wl] = parse_file(fname) if fname.exists() else {}
    return result


# ── box-plot helpers ────────────────────────────────────────────────────────
def group_positions(n_groups: int, gap: float = 0.25) -> tuple[list, list]:
    """Two boxes per group (ubuntu left, wsl right), groups spaced 1 unit."""
    half = gap / 2
    return (
        [i - half for i in range(n_groups)],
        [i + half for i in range(n_groups)],
    )


def draw_boxes(ax, positions, values, color, flier_size=2):
    if not any(v for v in values):
        return
    ax.boxplot(
        values,
        positions=positions,
        widths=0.20,
        patch_artist=True,
        notch=False,
        showfliers=True,
        flierprops=dict(marker=".", markersize=flier_size,
                        markerfacecolor=color, alpha=0.30,
                        linestyle="none"),
        medianprops=dict(color="black", linewidth=2.0),
        boxprops=dict(facecolor=color, alpha=ALPHA_BOX, linewidth=0.8),
        whiskerprops=dict(linewidth=0.8, linestyle="--"),
        capprops=dict(linewidth=1.0),
    )


def annotate_medians(ax, u_vals, w_vals, u_pos, w_pos, scale):
    """
    Print median values just ABOVE each box using axes-fraction y so they
    always land outside the data area and never collide with the xlabel
    (which is at the bottom).  clip=False lets them escape the top boundary.
    """
    for i in range(len(ENGINES)):
        for vals, x, color in [
            (u_vals[i], u_pos[i], COLORS["ubuntu"]),
            (w_vals[i], w_pos[i], COLORS["wsl"]),
        ]:
            if vals:
                med = float(np.median(vals)) * scale
                ax.annotate(
                    f"{med:.1f}" if scale < 1.0 else f"{med:.0f}",
                    xy=(x, 1.0),
                    xycoords=("data", "axes fraction"),
                    xytext=(0, 3),           # 3 pt above the top edge
                    textcoords="offset points",
                    ha="center", va="bottom",
                    fontsize=6.0, color=color, fontweight="bold",
                    annotation_clip=False,
                )


# ── main ───────────────────────────────────────────────────────────────────
def main():
    data = load_all()

    n_rows = len(WORKLOADS)
    n_cols = len(METRICS)

    # tall figure: rows stacked vertically, 5 columns side-by-side
    fig, axes = plt.subplots(
        n_rows, n_cols,
        figsize=(4.2 * n_cols, 3.6 * n_rows),
        squeeze=False,
    )

    fig.suptitle(
        "Experiment 1 — Ubuntu vs WSL  ·  IQR + tails  (30 runs each)\n"
        "Blue = Ubuntu  ·  Orange = WSL  ·  black line = median  ·  x-axis: v1 / v2 / v3",
        fontsize=11, y=1.005, va="bottom",
    )

    u_pos, w_pos = group_positions(len(ENGINES))

    for row_i, wl in enumerate(WORKLOADS):
        for col_i, (metric_key, col_label, scale, unit) in enumerate(METRICS):
            ax = axes[row_i][col_i]

            # gather scaled values
            u_vals = [
                [v * scale for v in data["ubuntu"][eng][wl].get(metric_key, [])]
                for eng in ENGINES
            ]
            w_vals = [
                [v * scale for v in data["wsl"][eng][wl].get(metric_key, [])]
                for eng in ENGINES
            ]

            draw_boxes(ax, u_pos, u_vals, COLORS["ubuntu"])
            draw_boxes(ax, w_pos, w_vals, COLORS["wsl"])
            annotate_medians(ax, u_vals, w_vals, u_pos, w_pos, scale=1.0)

            # ── axis cosmetics ─────────────────────────────────
            ax.set_xticks(range(len(ENGINES)))
            ax.set_xticklabels(ENGINES, fontsize=9)
            ax.set_xlim(-0.55, len(ENGINES) - 0.45)
            ax.yaxis.grid(True, linestyle="--", linewidth=0.5, alpha=0.6)
            ax.set_axisbelow(True)
            ax.tick_params(axis="y", labelsize=7)

            # metric label at BOTTOM so the top is clear for median text
            ax.set_xlabel(f"{col_label}  ({unit})", fontsize=8.5, labelpad=3)

            # row label (workload) on the left-most column only
            if col_i == 0:
                ax.set_ylabel(
                    wl.replace("_", "\n"),
                    fontsize=8, labelpad=5, rotation=0,
                    ha="right", va="center",
                )

            # column header at the very TOP — only on the first row
            if row_i == 0:
                ax.set_title(
                    f"{col_label}  ({unit})",
                    fontsize=9, pad=14,    # pad=14 leaves room for median text
                    fontweight="bold",
                )

    # ── shared legend ────────────────────────────────────────────
    legend_handles = [
        mpatches.Patch(facecolor=COLORS["ubuntu"], alpha=ALPHA_BOX, label="Ubuntu"),
        mpatches.Patch(facecolor=COLORS["wsl"],    alpha=ALPHA_BOX, label="WSL"),
    ]
    fig.legend(
        handles=legend_handles,
        loc="lower center",
        ncol=2,
        fontsize=10,
        frameon=True,
        bbox_to_anchor=(0.5, -0.005),
    )

    plt.tight_layout(rect=[0.06, 0.015, 1.0, 1.0])
    fig.savefig(OUT_FILE, dpi=150, bbox_inches="tight")
    print(f"Saved → {OUT_FILE}")

    # ── quick text summary ───────────────────────────────────────
    print("\n── Median summary (Ubuntu | WSL) ──")
    for wl in WORKLOADS:
        print(f"\n  {wl}")
        for engine in ENGINES:
            parts = [f"    {engine}"]
            for metric_key, col_label, scale, unit in METRICS:
                u = [v * scale for v in data["ubuntu"][engine][wl].get(metric_key, [])]
                w = [v * scale for v in data["wsl"][engine][wl].get(metric_key, [])]
                u_m = f"{np.median(u):.1f}" if u else "—"
                w_m = f"{np.median(w):.1f}" if w else "—"
                parts.append(f"{col_label}: {u_m}|{w_m} {unit}")
            print("  ".join(parts))


if __name__ == "__main__":
    main()
