#!/usr/bin/env python3
"""
plot_latency_cdf.py — per-order latency distribution figures for the Phase 2
run-matrix sweep (see sweep.sh in this directory).

For every testcase found in --results-dir, produces two figures:

  cdf_v4_<testcase>.png   v3 (single-owner reference) + v4 @ every thread count
  cdf_v5_<testcase>.png   v5s (flat-array control)    + v5 @ every thread count

Axes:
  y — percentile, log-scaled in the *remaining* fraction: each gridline step
      divides the tail by 10 (p0 → p90 → p99 → p99.9 → …). Higher percentiles
      sit higher on the axis.
  x — per-order latency in ns (log scale by default; --linear-x to override).
      The latency is stamped at submit-call entry, so lock wait is included —
      contention shows up directly as the tail fattening.

Each curve is the empirical CCDF: y = fraction of orders with latency >= x,
pooled across every .lat*.csv dump found for that config × testcase.

A table-view twin (percentile summary per config) is written next to each
figure as cdf_<fam>_<testcase>.summary.csv and echoed to stdout.

Usage (from the repo root):
  python3 experiments/multithread_bench/plot_latency_cdf.py
  python3 experiments/multithread_bench/plot_latency_cdf.py \
      --results-dir results/multithread_bench --out-dir results/multithread_bench
"""

import argparse
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ── families: figure key → (reference config, threaded engine prefix) ───────
FAMILIES = {
    "v4": ("v3", "v4"),
    "v5": ("v5s", "v5"),
}

# ── palette (dataviz reference instance, light mode) ────────────────────────
# Thread counts are ordered, so they get the validated ordinal blue ramp
# (light → dark = fewer → more threads). The single-threaded reference is a
# different kind of entity and wears primary ink, not a ramp step.
REF_INK = "#0b0b0b"
ORDINAL_RAMP = [  # sequential blue steps 250..700, ordinal-legal on light
    "#86b6ef", "#6da7ec", "#5598e7", "#3987e5", "#2a78d6",
    "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b",
]
SURFACE = "#fcfcfb"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRIDLINE = "#e1e0d9"
BASELINE = "#c3c2b7"

FILE_RE = re.compile(
    r"^(?P<config>v3|v5s|v4_t\d+|v5_t\d+)_(?P<test>.+?)\.lat(?:\.rep\d+)?\.csv$"
)

SUMMARY_QUANTILES = [
    ("p50", 0.50), ("p90", 0.90), ("p99", 0.99),
    ("p99.9", 0.999), ("p99.99", 0.9999),
]


def ramp_colors(n: int) -> list[str]:
    """n evenly spread steps from the ordinal ramp, always ending darkest."""
    if n <= 0:
        return []
    if n == 1:
        return [ORDINAL_RAMP[-1]]
    idx = np.linspace(0, len(ORDINAL_RAMP) - 1, n).round().astype(int)
    return [ORDINAL_RAMP[i] for i in idx]


def load_latencies(path: Path) -> np.ndarray:
    """Read the latency_ns column of a BENCH_PERF_DUMP csv."""
    with open(path) as f:
        header = f.readline()
        if "," in header:  # perf-counter columns present — take column 0
            return np.loadtxt(f, delimiter=",", usecols=0, dtype=np.int64, ndmin=1)
        return np.array(f.read().split(), dtype=np.int64)


def ccdf_points(sorted_lat: np.ndarray, pts_per_decade: int = 96):
    """Downsampled empirical CCDF: y_i = P(latency >= x_i), y in [1/n, 1]."""
    n = sorted_lat.size
    decades = math.log10(n)
    ys = 10.0 ** -np.linspace(0.0, decades, int(decades * pts_per_decade) + 1)
    idx = np.unique(np.clip(n - np.ceil(ys * n).astype(np.int64), 0, n - 1))
    return sorted_lat[idx], (n - idx) / n


def percentile_tick_label(k: int) -> str:
    if k == 0:
        return "p0"
    if k == 1:
        return "p90"
    return "p99" + ("." + "9" * (k - 2) if k > 2 else "")


def discover(results_dir: Path) -> dict[tuple[str, str], list[Path]]:
    """(config, testcase) → list of dump files (multiple when --dump-all)."""
    found = defaultdict(list)
    for p in sorted(results_dir.glob("*.lat*.csv")):
        m = FILE_RE.match(p.name)
        if m:
            found[(m.group("config"), m.group("test"))].append(p)
    return found


def thread_count(config: str) -> int:
    return int(config.rsplit("_t", 1)[1])


def style_axes(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("bottom", "left"):
        ax.spines[side].set_color(BASELINE)
        ax.spines[side].set_linewidth(0.8)
    ax.tick_params(colors=INK_MUTED, labelcolor=INK_MUTED, labelsize=9,
                   which="both")
    ax.grid(True, which="major", color=GRIDLINE, linewidth=0.6)
    ax.set_axisbelow(True)


def plot_family(fam: str, test: str, series: list[tuple[str, np.ndarray, str, float]],
                out_dir: Path, linear_x: bool, dpi: int) -> None:
    ref_cfg, eng = FAMILIES[fam]

    fig, ax = plt.subplots(figsize=(8.0, 5.2))
    fig.set_facecolor(SURFACE)
    style_axes(ax)

    n_max = max(lat.size for _, lat, _, _ in series)
    max_decade = int(math.floor(math.log10(n_max)))

    for label, lat, color, lw in series:
        x, y = ccdf_points(lat)
        ax.plot(x, y, color=color, linewidth=lw, label=label,
                solid_capstyle="round", zorder=3)

    if not linear_x:
        ax.set_xscale("log")
    ax.set_yscale("log")
    # Inverted axis: p0 at the bottom, deepest tail at the top. The top limit
    # sits past 1/n_max so no curve's last point is clipped.
    ax.set_ylim(1.5, (1.0 / n_max) / 1.6)

    ticks = [10.0 ** -k for k in range(0, max_decade + 1)]
    ax.set_yticks(ticks)
    ax.set_yticklabels([percentile_tick_label(k) for k in range(0, max_decade + 1)])
    ax.minorticks_off()

    ax.set_xlabel("per-order latency (ns)", color=INK_MUTED, fontsize=10)
    ax.set_ylabel("percentile (tail ÷10 per step)", color=INK_MUTED, fontsize=10)

    ax.set_title(f"{eng} vs {ref_cfg} — latency distribution · {test}",
                 loc="left", color=REF_INK, fontsize=12, pad=18)
    ax.text(0.0, 1.015, "empirical CCDF, pooled per-order samples; "
            "latency includes lock wait",
            transform=ax.transAxes, color=INK_SECONDARY, fontsize=9)

    leg = ax.legend(loc="upper left", frameon=False, fontsize=9,
                    labelcolor=INK_SECONDARY, handlelength=1.6)
    for line in leg.get_lines():
        line.set_linewidth(2.4)

    fig.tight_layout()
    out = out_dir / f"cdf_{fam}_{test}.png"
    fig.savefig(out, dpi=dpi, facecolor=SURFACE, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote {out}")


def write_summary(fam: str, test: str, series: list[tuple[str, np.ndarray, str, float]],
                  out_dir: Path) -> None:
    out = out_dir / f"cdf_{fam}_{test}.summary.csv"
    names = [name for name, _ in SUMMARY_QUANTILES]
    with open(out, "w") as f:
        f.write("config,n_samples," + ",".join(f"{n}_ns" for n in names) + ",max_ns\n")
        print(f"  {'config':<20}" + "".join(f"{n:>12}" for n in names) + f"{'max':>12}")
        for label, lat, _, _ in series:
            qs = [lat[min(int(q * lat.size), lat.size - 1)] for _, q in SUMMARY_QUANTILES]
            f.write(f"{label},{lat.size}," + ",".join(str(v) for v in qs)
                    + f",{lat[-1]}\n")
            print(f"  {label:<20}" + "".join(f"{v:>12}" for v in qs) + f"{lat[-1]:>12}")
    print(f"  wrote {out}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", default="results/multithread_bench",
                    help="directory holding the sweep's .lat*.csv dumps")
    ap.add_argument("--out-dir", default=None,
                    help="where to write figures (default: results-dir)")
    ap.add_argument("--linear-x", action="store_true",
                    help="linear latency axis instead of log")
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

    found = discover(results_dir)
    if not found:
        print(f"[error] no .lat*.csv dumps found in {results_dir} — run sweep.sh first",
              file=sys.stderr)
        return 1

    tests = sorted({t for _, t in found})
    cache: dict[tuple[str, str], np.ndarray] = {}

    def pooled(config: str, test: str) -> np.ndarray | None:
        key = (config, test)
        if key not in found:
            return None
        if key not in cache:
            lat = np.concatenate([load_latencies(p) for p in found[key]])
            lat.sort()
            cache[key] = lat
        return cache[key]

    n_figs = 0
    for test in tests:
        for fam, (ref_cfg, eng) in FAMILIES.items():
            configs = sorted((c for c, t in found
                              if t == test and c.startswith(f"{eng}_t")),
                             key=thread_count)
            series: list[tuple[str, np.ndarray, str, float]] = []

            ref_lat = pooled(ref_cfg, test)
            if ref_lat is not None:
                series.append((f"{ref_cfg} (single-owner)", ref_lat, REF_INK, 2.0))

            colors = ramp_colors(len(configs))
            for cfg, color in zip(configs, colors):
                t = thread_count(cfg)
                series.append((f"{eng} · {t} thread{'s' if t > 1 else ''}",
                               pooled(cfg, test), color, 1.8))

            if len(series) < 2:
                print(f"[warn] {fam} × {test}: only {len(series)} config(s) with "
                      f"dumps — skipping figure", file=sys.stderr)
                continue

            print(f"{fam} × {test}:")
            plot_family(fam, test, series, out_dir, args.linear_x, args.dpi)
            write_summary(fam, test, series, out_dir)
            n_figs += 1

    print(f"\n{n_figs} figure(s) written to {out_dir}")
    return 0 if n_figs else 1


if __name__ == "__main__":
    sys.exit(main())
