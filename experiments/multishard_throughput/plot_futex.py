#!/usr/bin/env python3
"""Plot FUTEX syscall rate per order for engine_v6a, by instrument skew and price mode.

WHAT THIS IS TESTING

The V6A saturation sweep says uniform (3 shards sharing the work) is *slower* than
one-hot (1 shard doing all of it). The hypothesis is the condition variable's wakeup
floor, not the matcher and not mutex contention:

    cv.wait(lock, pred)   pred TRUE  on entry -> returns, NO syscall
                          pred FALSE on entry -> FUTEX_WAIT, the thread sleeps
    cv.notify_one()       no waiter registered -> returns, NO syscall
                          a waiter registered  -> FUTEX_WAKE syscall  (~1-2 us)

so the cv is free on a backlogged queue and catastrophic on an empty one, and the
per-item cost is (wakeup cost) / (items drained per wakeup) -- i.e. QUEUE DEPTH IS THE
AMORTIZATION FACTOR. Little's law on the sweep's own numbers gives depth ~260,000 for
one-hot and ~1 for uniform.

    PREDICTION:  uniform, zipf  ->  ~1+ futex syscalls per order
                 one-hot        ->  ~0  (startup and shutdown only)

A ~1000x spread confirms it. A flat chart refutes it, and the cause is elsewhere.

    LOG Y-AXIS, DELIBERATELY. The whole claim is about orders of magnitude. A linear
    axis would render one-hot as a zero-height bar and hide the very thing being
    measured.

FIGURES

  futex_per_order.png     the headline. Grouped bars: x = skew, series = price mode,
                          y = futex syscalls per order (log). The dashed rule at y=1
                          is "one syscall per order" -- the wakeup floor's signature.

  futex_vs_throughput.png the inference. Each testcase as a point: futex/order (log)
                          against the throughput it achieved. If the hypothesis holds,
                          the six points fall on a downward line -- syscall rate, not
                          shard count, predicts throughput.

                          Throughput here is read from the CLEAN sweep
                          (results/multishard_throughput/), not from the probe run,
                          because counting a tracepoint perturbs the timing. See the
                          perturbation warning in futex_probe.sh.

INPUT   results/multishard_futex/futex_counts_<engine>_N<N>_S<S>.csv  (from futex_probe.sh)
        results/multishard_throughput/*.txt           (optional; for clean throughput)

If futex_probe.sh ran with --no-perf there is no futex column, and this script falls
back to voluntary context switches per order (getrusage), which measures the same
sleeps by a different route. The titles say which one you are looking at.

USAGE
    python3 experiments/multishard_throughput/plot_futex.py
    python3 experiments/multishard_throughput/plot_futex.py --shards 2 --producers 2
"""

import argparse
import csv
import re
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Palette — the same tokens plot_throughput.py uses, so the two figures read as one
# system. Categorical slots are taken in their documented order (that ordering IS the
# CVD-safety mechanism); ink tokens carry every piece of text, so no value or label
# ever wears its series colour.
# ---------------------------------------------------------------------------
SERIES = ["#2a78d6", "#1baf7a", "#eda100"]  # slots 1 (blue), 2 (aqua), 3 (yellow)
C_RULE = "#52514e"    # secondary ink: the y=1 reference rule
C_TEXT = "#0b0b0b"    # primary ink
C_MUTED = "#898781"   # axis / secondary labels
C_GRID = "#e1e0d9"
C_SURFACE = "#fcfcfb"

SKEWS = ["uniform", "zipf", "one-hot"]
PRICE_MODES = ["heavy_overlap", "wide_range"]
MARKERS = {"heavy_overlap": "o", "wide_range": "s"}

OPS_RE = re.compile(r"^operations_per_sec=([0-9.]+)\s*$")
LABEL_RE = re.compile(r"^(Queue|Match|Total) stats:\s*$")


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
def load_probe(path: Path) -> Tuple[Dict[Tuple[str, str], Dict[str, float]], str]:
    """Median per-order syscall rate for each (skew, prices) cell.

    Returns (cells, metric_name). Prefers the perf futex counter; falls back to
    getrusage voluntary context switches when the probe ran with --no-perf.
    """
    if not path.exists():
        print(f"[error] no probe data at {path}\n"
              f"        run: ./experiments/multishard_throughput/futex_probe.sh",
              file=sys.stderr)
        raise SystemExit(1)

    rows = list(csv.DictReader(path.open()))
    if not rows:
        print(f"[error] {path} has no rows", file=sys.stderr)
        raise SystemExit(1)

    def column_is_populated(name: str) -> bool:
        return any((r.get(name) or "").strip() for r in rows)

    if column_is_populated("futex"):
        column, metric = "futex", "futex syscalls"
    elif column_is_populated("vol_ctxsw"):
        column, metric = "vol_ctxsw", "voluntary context switches"
        print("[warn] no futex column (probe ran with --no-perf); "
              "falling back to voluntary context switches", file=sys.stderr)
    else:
        print(f"[error] {path} has neither a futex nor a vol_ctxsw column populated",
              file=sys.stderr)
        raise SystemExit(1)

    per_cell: Dict[Tuple[str, str], List[float]] = {}
    also_futex2: List[float] = []
    for r in rows:
        raw, orders = (r.get(column) or "").strip(), (r.get("orders") or "").strip()
        if not raw or not orders or float(orders) == 0:
            continue
        key = (r["skew"], r["prices"])
        per_cell.setdefault(key, []).append(float(raw) / float(orders))
        for f2 in ("futex2_wait", "futex2_wake"):
            v = (r.get(f2) or "").strip()
            if v:
                also_futex2.append(float(v))

    # glibc 2.39 uses the classic futex(2). If the futex2 syscalls ever fire, the
    # `futex` column is no longer the whole story and every number below is an
    # undercount — so say so loudly rather than quietly plotting a wrong bar.
    if also_futex2 and max(also_futex2) > 0:
        print(f"[warn] futex2 syscalls are NON-ZERO (max {max(also_futex2):.0f}). "
              f"The `futex` column is an undercount on this glibc.", file=sys.stderr)

    # The probe records its own config per row. Use THAT rather than CLI defaults, so a
    # --producers mismatch cannot silently pair these futex counts with another config's
    # (possibly stale, pre-cpu0-fix) throughput files.
    labels = {(r.get("label") or "").strip() for r in rows if (r.get("label") or "").strip()}
    probe_label = labels.pop() if len(labels) == 1 else None
    if labels:
        print(f"[warn] {path} mixes multiple configs; throughput pairing disabled",
              file=sys.stderr)
        probe_label = None

    cells = {
        key: {
            "median": statistics.median(v),
            "lo": statistics.median(v) - (statistics.quantiles(v, n=4)[0] if len(v) >= 4 else statistics.median(v)),
            "hi": (statistics.quantiles(v, n=4)[2] if len(v) >= 4 else statistics.median(v)) - statistics.median(v),
            "n": len(v),
        }
        for key, v in per_cell.items()
    }
    return cells, metric, probe_label


def parse_throughputs(path: Path) -> List[float]:
    """Every run's operations_per_sec in a key=value stats file.

    V6A prints three blocks per run (Queue/Match/Total) that share one batch span and
    one sample count, so operations_per_sec is identical in all three; we take Total.
    """
    if not path.exists():
        return []
    runs: List[float] = []
    label: Optional[str] = None
    per_run: Dict[Optional[str], float] = {}

    def flush() -> None:
        if per_run:
            runs.append(per_run.get("Total", next(iter(per_run.values()))))
            per_run.clear()

    for line in path.read_text().splitlines():
        line = line.strip()
        if line == "---":
            flush()
            label = None
            continue
        m = LABEL_RE.match(line)
        if m:
            label = m.group(1)
            continue
        m = OPS_RE.match(line)
        if m:
            per_run[label] = float(m.group(1))
    flush()
    return runs


def load_clean_throughput(sweep_dir: Path, label: str, shards: int) -> Dict[Tuple[str, str], float]:
    """Median throughput per cell from the UNPERTURBED sweep, if it has been run."""
    out: Dict[Tuple[str, str], float] = {}
    for skew in SKEWS:
        for prices in PRICE_MODES:
            runs = parse_throughputs(sweep_dir / f"{label}_multi_{shards}_{skew}_{prices}.txt")
            if runs:
                out[(skew, prices)] = statistics.median(runs)
    return out


# ---------------------------------------------------------------------------
# Figure 1 — the headline
# ---------------------------------------------------------------------------
def plot_per_order(cells, metric: str, engine: str, shards: int, producers: int, out_path: Path) -> None:
    fig, ax = plt.subplots(figsize=(9.2, 5.6))
    fig.patch.set_facecolor(C_SURFACE)
    ax.set_facecolor(C_SURFACE)

    width = 0.30
    present = [p for p in PRICE_MODES if any((s, p) in cells for s in SKEWS)]
    values_seen: List[float] = []

    for j, prices in enumerate(present):
        offset = (j - (len(present) - 1) / 2) * (width + 0.03)  # surface gap between fills
        xs, ys, lo, hi = [], [], [], []
        for i, skew in enumerate(SKEWS):
            cell = cells.get((skew, prices))
            if not cell:
                continue
            xs.append(i + offset)
            ys.append(max(cell["median"], 1e-6))
            lo.append(cell["lo"])
            hi.append(cell["hi"])
        values_seen.extend(ys)
        bars = ax.bar(xs, ys, width=width, color=SERIES[j], zorder=3,
                      yerr=[lo, hi], ecolor=C_RULE, capsize=3,
                      label=prices.replace("_", " "))
        # Direct value labels: identity is never colour-alone, and on a log axis the
        # eye cannot read a magnitude off the bar height anyway.
        for bar, value in zip(bars, ys):
            ax.annotate(f"{value:.3g}",
                        xy=(bar.get_x() + bar.get_width() / 2, value),
                        xytext=(0, 5), textcoords="offset points",
                        ha="center", va="bottom", fontsize=9,
                        fontweight="bold", color=C_TEXT, zorder=6)

    floor = min(values_seen) / 6 if values_seen else 1e-4
    # Headroom above the y=1 rule, so the rule and its label clear the legend.
    top = max(max(values_seen) * 6, 3.5) if values_seen else 3.5
    ax.set_yscale("log")
    ax.set_ylim(floor, top)

    # The signature of the wakeup floor: one syscall for every order that passes
    # through the queue. Above this line, every handoff is going to the kernel.
    # Label rides the left edge — the legend owns the upper right. x is in axes
    # fraction, y in data, so the label tracks the rule regardless of the y range.
    if floor < 1.0 < top:
        ax.axhline(1.0, linestyle=(0, (4, 3)), linewidth=1.8, color=C_RULE, zorder=4)
        ax.annotate("1 syscall per order  —  every handoff enters the kernel",
                    xy=(0.012, 1.0), xycoords=("axes fraction", "data"),
                    xytext=(0, 5), textcoords="offset points",
                    ha="left", va="bottom", fontsize=8.5, color=C_RULE)

    ax.set_xticks(range(len(SKEWS)))
    ax.set_xticklabels([f"{s}\n({shards} shards)" for s in SKEWS],
                       fontsize=10, color=C_TEXT)
    ax.set_ylabel(f"{metric} per order  (log scale)", fontsize=10, color=C_TEXT)
    ax.set_title(f"Kernel entries at the shard boundary — {metric} per order, {engine} "
                 f"N={producers} S={shards}",
                 fontsize=13, color=C_TEXT, pad=14, loc="left")
    ax.annotate("empty queue → consumer sleeps → every push must FUTEX_WAKE.  "
                "Backlogged queue → predicate already true → no syscall at all.",
                xy=(0, 1.015), xycoords="axes fraction", fontsize=8.5, color=C_MUTED)

    ax.grid(axis="y", color=C_GRID, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color("#c3c2b7")
    ax.tick_params(axis="y", colors=C_MUTED, length=0)
    ax.tick_params(axis="y", which="minor", length=0)  # log minor ticks read as clutter
    ax.tick_params(axis="x", colors=C_TEXT, length=0, pad=8)
    ax.legend(frameon=False, fontsize=9, loc="upper right", labelcolor=C_TEXT,
              title="price distribution", title_fontsize=9)

    fig.savefig(out_path, dpi=160, facecolor=C_SURFACE, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Figure 2 — the inference
# ---------------------------------------------------------------------------
def plot_vs_throughput(cells, metric: str, clean, shards: int, out_path: Path) -> bool:
    points = [(skew, prices, cells[(skew, prices)]["median"], clean[(skew, prices)])
              for skew in SKEWS for prices in PRICE_MODES
              if (skew, prices) in cells and (skew, prices) in clean]
    if len(points) < 2:
        return False

    fig, ax = plt.subplots(figsize=(9.2, 5.6))
    fig.patch.set_facecolor(C_SURFACE)
    ax.set_facecolor(C_SURFACE)

    rates = [max(r, 1e-6) for _, _, r, _ in points]
    lo, hi = min(rates), max(rates)
    midpoint = (lo * hi) ** 0.5  # geometric mid — the axis is log

    for skew, prices, rate, thpt in points:
        rate = max(rate, 1e-6)
        ax.plot(rate, thpt / 1e6,
                marker=MARKERS[prices], markersize=11,
                color=SERIES[SKEWS.index(skew)],
                markeredgecolor=C_SURFACE, markeredgewidth=2.0,  # 2px surface ring
                linestyle="none", zorder=4)
        # Points cluster into two tight groups, so labels need four distinct slots: flip
        # the label inboard on the right half of the axis, and split the two price modes
        # above/below the marker.
        on_right = rate > midpoint
        ax.annotate(f"{skew} · {prices.split('_')[0]}",
                    xy=(rate, thpt / 1e6),
                    xytext=(-14 if on_right else 14,
                            10 if prices == "heavy_overlap" else -15),
                    textcoords="offset points",
                    ha="right" if on_right else "left",
                    fontsize=8.5, color=C_TEXT, zorder=5)

    ax.set_xscale("log")
    ax.set_xlim(lo / 2.5, hi * 2.5)
    ax.set_xlabel(f"{metric} per order  (log scale)", fontsize=10, color=C_TEXT)
    ax.set_ylabel("throughput (millions of orders/sec)", fontsize=10, color=C_TEXT)
    ax.set_ylim(0, max(t for _, _, _, t in points) / 1e6 * 1.25)
    ax.set_title("Syscall rate predicts throughput — shard count does not",
                 fontsize=13, color=C_TEXT, pad=14, loc="left")
    ax.annotate("throughput from the CLEAN sweep (results/multishard_throughput/); "
                "syscall rate from the perf probe, whose own overhead perturbs timing",
                xy=(0, 1.015), xycoords="axes fraction", fontsize=8.5, color=C_MUTED)

    ax.grid(color=C_GRID, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("bottom", "left"):
        ax.spines[side].set_color("#c3c2b7")
    ax.tick_params(colors=C_MUTED, length=0)

    handles = [plt.Line2D([], [], marker="o", linestyle="none", markersize=9,
                          color=SERIES[i], label=s) for i, s in enumerate(SKEWS)]
    handles += [plt.Line2D([], [], marker=MARKERS[p], linestyle="none", markersize=9,
                           color=C_MUTED, label=p.replace("_", " ")) for p in PRICE_MODES]
    ax.legend(handles=handles, frameon=False, fontsize=9, loc="upper right",
              labelcolor=C_TEXT, ncol=2)

    fig.savefig(out_path, dpi=160, facecolor=C_SURFACE, bbox_inches="tight")
    plt.close(fig)
    return True


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Plot futex syscall rate per order for V6A.")
    p.add_argument("--engine", default="v6a",
                   help="v6a (MutexQueue+cv) | v6a_nb (NonblockingMutexQueue, spin)")
    p.add_argument("--probe-csv", default=None,
                   help="default: results/multishard_futex/futex_counts_<engine>_N<N>_S<S>.csv")
    p.add_argument("--sweep-dir", default="results/multishard_throughput",
                   help="the CLEAN throughput sweep, for figure 2")
    p.add_argument("--output-dir", default="results/multishard_futex")
    p.add_argument("--shards", type=int, default=3)
    p.add_argument("--producers", type=int, default=3)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parents[2]
    out_dir = root / args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    label_cli = f"{args.engine}_N{args.producers}_S{args.shards}"
    probe_csv = Path(args.probe_csv) if args.probe_csv \
        else Path("results/multishard_futex") / f"futex_counts_{label_cli}.csv"
    cells, metric, probe_label = load_probe(root / probe_csv)
    # Prefer the config the probe recorded; fall back to the CLI only if absent.
    label = probe_label or f"{args.engine}_N{args.producers}_S{args.shards}"
    if probe_label:
        print(f"[info] config from probe CSV: {probe_label}")
    clean = load_clean_throughput(root / args.sweep_dir, label, args.shards)

    p1 = out_dir / f"futex_per_order_{label_cli}.png"
    plot_per_order(cells, metric, args.engine, args.shards, args.producers, p1)
    print(f"wrote {p1}")

    p2 = out_dir / f"futex_vs_throughput_{label_cli}.png"
    if plot_vs_throughput(cells, metric, clean, args.shards, p2):
        print(f"wrote {p2}")
    else:
        print(f"[skip] {p2.name}: needs the clean sweep in {args.sweep_dir}\n"
              f"       run: ./experiments/multishard_throughput/sweep.sh", file=sys.stderr)

    print()
    print(f"median {metric} per order:")
    for skew in SKEWS:
        for prices in PRICE_MODES:
            cell = cells.get((skew, prices))
            if not cell:
                continue
            thpt = clean.get((skew, prices))
            extra = f"   (clean throughput {thpt / 1e6:.2f}M ops/s)" if thpt else ""
            print(f"  {skew:<9} {prices:<14} {cell['median']:9.4f}  "
                  f"(n={cell['n']}){extra}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
