#!/usr/bin/env python3
"""
Per-order cache-miss distribution plots (v1 vs v2 vs v3, per workload).

Reads raw per-order CSVs produced by bench_sweep.sh:
    results/cache_distribution_analysis/raw_<engine>_<workload>_run<NN>.csv

Each CSV row is one matched/inserted order, captured by the BenchmarkRunner's
rdpmc bracket. Columns:
    latency_ns, cache-misses, LLC-load-misses, dTLB-load-misses

For each workload we produce ONE figure file:
    cache_dist_<workload>.png
with 3 subplots side-by-side (one per counter), each holding 3 box plots
(v1 / v2 / v3). Box = p25/p50/p75, whiskers = p1/p99, fliers above p99.
Annotations show p50 / p95 / p99 / p99.9 of the pooled per-order distribution.

The y-axis uses *symlog* — the per-order distribution is mostly 0 with a few
multi-thousand-event spikes, so linear hides the spikes and pure log can't
plot 0.

Run from anywhere:
    python3 experiments/cache_distribution_analysis/plot_distribution.py
    python3 experiments/cache_distribution_analysis/plot_distribution.py --input-dir results/cache_distribution_analysis
"""

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

ENGINES = ["v1", "v2", "v3"]

ENGINE_COLORS = {
    "v1": "#2196F3",   # blue
    "v2": "#4CAF50",   # green
    "v3": "#FF9800",   # orange
}
ALPHA_BOX = 0.60

# Counter columns (CSV header) → display label
METRICS = [
    ("cache-misses",     "cache-misses"),
    ("LLC-load-misses",  "LLC-load-misses"),
    ("dTLB-load-misses", "dTLB-load-misses"),
]

# Percentiles annotated on each box
ANNOT_PCTS = [50, 95, 99, 99.9]


# ── parsing ──────────────────────────────────────────────────────────────────
RAW_RE = re.compile(r"^raw_([^_]+)_(.+)_run\d+\.csv$")


def discover(input_dir: Path) -> dict[str, dict[str, list[Path]]]:
    """Return {workload: {engine: [csv_paths_for_all_runs]}}."""
    out: dict[str, dict[str, list[Path]]] = defaultdict(lambda: defaultdict(list))
    for f in input_dir.glob("raw_*.csv"):
        m = RAW_RE.match(f.name)
        if not m:
            continue
        engine, workload = m.group(1), m.group(2)
        if engine not in ENGINES:
            continue
        out[workload][engine].append(f)
    return out


# Per-order counter deltas above this are almost certainly rdpmc wrap-around
# (kernel preempted the bracket and rescheduled the counter — `end - start`
# in uint64 then wraps to a value near 2^64). 2^48 ≈ 2.8e14, vastly above any
# real per-order count we measure here, so dropping such rows is safe.
_MAX_SANE_VALUE = 1 << 48


def load_pooled(paths: list[Path]) -> dict[str, np.ndarray]:
    """Pool per-order rows across multiple run CSVs into one array per column.

    Rows are dropped ATOMICALLY (all columns at once) if any value fails to
    parse or exceeds _MAX_SANE_VALUE — this keeps per-order alignment between
    latency_ns and the cache event columns intact.

    Returned arrays are uint64 — counters are unsigned and the wrap-around
    edge case produces values that don't fit in int64.
    """
    cols: dict[str, list[int]] = defaultdict(list)
    dropped = 0
    total = 0
    for p in paths:
        with p.open() as fh:
            reader = csv.DictReader(fh)
            if reader.fieldnames is None:
                continue
            fieldnames = [f for f in reader.fieldnames if f]
            for row in reader:
                total += 1
                parsed: dict[str, int] = {}
                ok = True
                for k in fieldnames:
                    v = row.get(k)
                    if v is None:
                        ok = False
                        break
                    try:
                        n = int(v)
                    except ValueError:
                        ok = False
                        break
                    if n < 0 or n > _MAX_SANE_VALUE:
                        ok = False
                        break
                    parsed[k] = n
                if not ok:
                    dropped += 1
                    continue
                for k, n in parsed.items():
                    cols[k].append(n)
    if dropped:
        pct = 100.0 * dropped / max(total, 1)
        print(f"  [info] dropped {dropped:,} / {total:,} rows ({pct:.4f}%) "
              f"with bogus or wrapped counter values "
              f"(threshold > 2^48 — rdpmc preemption artifacts)")
    return {k: np.asarray(vs, dtype=np.uint64) for k, vs in cols.items() if vs}


# ── plotting ─────────────────────────────────────────────────────────────────
def draw_metric(ax, samples_by_engine: dict[str, dict[str, np.ndarray]],
                metric_key: str, label: str):
    positions, box_vals, used_eng = [], [], []
    for pos, eng in enumerate(ENGINES):
        col_map = samples_by_engine.get(eng)
        if not col_map:
            continue
        arr = col_map.get(metric_key)
        if arr is None or len(arr) == 0:
            continue
        positions.append(pos)
        box_vals.append(arr)
        used_eng.append(eng)

    if not box_vals:
        ax.text(0.5, 0.5, "no data", ha="center", va="center",
                transform=ax.transAxes, fontsize=8, color="#999999")
        return

    bp = ax.boxplot(
        box_vals,
        positions=positions,
        widths=0.55,
        patch_artist=True,
        whis=(1, 99),                 # whiskers at p1 / p99
        showfliers=True,
        flierprops=dict(marker=".", markersize=1.8, alpha=0.20, linestyle="none"),
        medianprops=dict(color="black", linewidth=1.8),
        whiskerprops=dict(linewidth=0.9, linestyle="--"),
        capprops=dict(linewidth=1.0),
    )
    for patch, eng in zip(bp["boxes"], used_eng):
        patch.set_facecolor(ENGINE_COLORS[eng])
        patch.set_alpha(ALPHA_BOX)
        patch.set_linewidth(0.8)

    # Annotate p50 / p95 / p99 / p99.9 right of each box
    for pos, arr, eng in zip(positions, box_vals, used_eng):
        pcts = np.percentile(arr, ANNOT_PCTS)
        text_lines = [f"n={len(arr):,}"]
        for pct, val in zip(ANNOT_PCTS, pcts):
            label_pct = f"p{pct:g}"
            text_lines.append(f"{label_pct}={int(val):,}")
        ax.annotate(
            "\n".join(text_lines),
            xy=(pos + 0.30, 1.0), xycoords=("data", "axes fraction"),
            xytext=(0, -2), textcoords="offset points",
            ha="left", va="top", fontsize=6.0,
            color=ENGINE_COLORS[eng], fontweight="bold",
            annotation_clip=False,
        )

    # Symlog so 0 is plottable and the spike tail is visible.
    ax.set_yscale("symlog", linthresh=1.0)
    ax.yaxis.grid(True, which="both", linestyle="--", linewidth=0.5, alpha=0.6)
    ax.set_axisbelow(True)
    ax.set_xticks(range(len(ENGINES)))
    ax.set_xticklabels(ENGINES, fontsize=9)
    ax.set_xlim(-0.55, len(ENGINES) - 0.45 + 0.6)   # room for annotations
    ax.tick_params(axis="y", labelsize=7)
    ax.set_title(label, fontsize=10, fontweight="bold", pad=6)
    ax.set_ylabel("events per order  (symlog)", fontsize=8)


def render_workload(workload: str,
                    samples_by_engine: dict[str, dict[str, np.ndarray]],
                    out_path: Path) -> None:
    fig, axes = plt.subplots(1, len(METRICS), figsize=(5.2 * len(METRICS), 4.6))
    if len(METRICS) == 1:
        axes = [axes]

    for ax, (key, label) in zip(axes, METRICS):
        draw_metric(ax, samples_by_engine, key, label)

    fig.suptitle(
        f"Per-order cache-miss distribution  ·  workload: {workload}\n"
        "box = p25/p50/p75   ·   whiskers = p1/p99   ·   dots = per-order outliers above p99",
        fontsize=11, y=1.005, va="bottom",
    )

    legend_handles = [
        mpatches.Patch(facecolor=ENGINE_COLORS[e], alpha=ALPHA_BOX, label=e)
        for e in ENGINES
    ]
    fig.legend(handles=legend_handles, loc="lower center", ncol=len(ENGINES),
               fontsize=10, frameon=True, bbox_to_anchor=(0.5, -0.005))

    plt.tight_layout(rect=[0.0, 0.02, 1.0, 1.0])
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved → {out_path}")


def print_summary(workload: str, samples_by_engine: dict[str, dict[str, np.ndarray]]) -> None:
    print(f"\n── {workload} ──")
    hdr = f"  {'engine':<6}{'metric':<20}{'n':>10}{'mean':>10}{'p50':>8}{'p95':>8}{'p99':>10}{'p99.9':>10}{'max':>12}"
    print(hdr)
    for eng in ENGINES:
        col_map = samples_by_engine.get(eng) or {}
        for key, _label in METRICS:
            arr = col_map.get(key)
            if arr is None or len(arr) == 0:
                continue
            p50, p95, p99, p999 = np.percentile(arr, [50, 95, 99, 99.9])
            print(
                f"  {eng:<6}{key:<20}{len(arr):>10,}{arr.mean():>10.3f}"
                f"{int(p50):>8,}{int(p95):>8,}{int(p99):>10,}{int(p999):>10,}"
                f"{int(arr.max()):>12,}"
            )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Box plots of per-order cache-miss distribution from rdpmc raw CSVs.")
    default_in = (Path(__file__).resolve().parent.parent.parent
                  / "results" / "cache_distribution_analysis")
    parser.add_argument("--input-dir", default=str(default_in),
                        help="dir with raw_<engine>_<workload>_run<NN>.csv "
                             "(default: results/cache_distribution_analysis)")
    parser.add_argument("--output-dir", default=None,
                        help="dir to write cache_dist_<workload>.png "
                             "(default: same as --input-dir)")
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir) if args.output_dir else input_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    discovered = discover(input_dir)
    if not discovered:
        print(f"[error] no raw_*.csv files found in {input_dir}")
        print("        run: experiments/cache_distribution_analysis/bench_sweep.sh")
        return 1

    for workload in sorted(discovered):
        samples_by_engine: dict[str, dict[str, np.ndarray]] = {}
        for eng in ENGINES:
            paths = discovered[workload].get(eng, [])
            if not paths:
                continue
            samples_by_engine[eng] = load_pooled(paths)

        out_path = output_dir / f"cache_dist_{workload}.png"
        render_workload(workload, samples_by_engine, out_path)
        print_summary(workload, samples_by_engine)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
