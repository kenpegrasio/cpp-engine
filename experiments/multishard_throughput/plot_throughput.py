#!/usr/bin/env python3
"""Plot V6A saturation throughput vs instrument skew, against the V5S baseline.

THROUGHPUT ONLY — by design. These runs are at saturation, where there is no
arrival process: every order is already queued when the run starts, so a per-order
"latency" is just "how long until the input ran out". It is bounded by input size,
not by the engine, and it is NOT a latency measurement. The stats files carry
latency percentiles; this script deliberately ignores every one of them and reads
only `operations_per_sec`. Latency becomes meaningful only under paced, open-loop
input at rho < 1 — that is the queue-latency preview, a different experiment.

One figure per price mode (heavy_overlap, wide_range). Each figure is four bars:

    v5s          single-threaded flat-array engine, ONE book, no queue.
                 This is mu -- the solo matcher's service capacity, the unit that
                 every other bar is denominated in.
    v6a uniform  3 shards, orders spread evenly
    v6a zipf     3 shards, p(rank r) ~ 1/r^s
    v6a one-hot  3 shards, every order to shard 0

Over each V6A bar sits a dashed cap: the predicted ceiling mu * H(N, s), where
H(N,s) = sum_{k=1..N} 1/k^s is the generalized harmonic number. The derivation:
shard of rank r takes fraction p(r) = (1/r^s) / H(N,s) of the flow, the system
saturates when the HOTTEST shard hits rho = 1 (idle cold shards do not help), so
lambda_max = mu / p(1) = mu * H(N,s). At N=3: uniform 3.00mu, zipf(s=1) 1.83mu,
one-hot 1.00mu.

The gap between bar and cap is the whole point of the plot. It is what partitioning
costs you that the arithmetic does not know about: the MutexQueue handoff, the
producer-side mutex contention (every shard queue here is MPSC -- all producers push
into all queues), and cache traffic. A bar that meets its cap means the shard
boundary is free; a bar far below means the queue is the bottleneck, not the matcher.

Inputs (key=value blocks, "---" between runs):
    results/multishard_throughput/v6a_N<P>_S<S>_multi_<S>_<skew>_<prices>.txt
    results/multithread_bench/v5s_<prices>_mixed.txt

Outputs:
    results/multishard_throughput/throughput_<prices>.png

Usage:
    python3 experiments/multishard_throughput/plot_throughput.py
    python3 experiments/multishard_throughput/plot_throughput.py --shards 2 --producers 2
"""

import argparse
import re
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Optional

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# Palette: categorical slot 1 (blue) for the measured V6A bars, neutral gray for
# the V5S baseline (a reference, not a peer series). Ink tokens for all text --
# a value label never wears its series colour.
# ---------------------------------------------------------------------------
C_V6A = "#2a78d6"      # categorical slot 1
C_V5S = "#8f8e88"      # neutral -- zero chroma, so CVD-safe against the blue
C_CEIL = "#52514e"     # secondary ink: the predicted-ceiling cap
C_TEXT = "#0b0b0b"     # primary ink
C_MUTED = "#898781"    # axis / secondary labels
C_GRID = "#e1e0d9"     # hairline gridline
C_SURFACE = "#fcfcfb"

SKEWS = ["uniform", "zipf", "one-hot"]
PRICE_MODES = ["heavy_overlap", "wide_range"]

OPS_RE = re.compile(r"^operations_per_sec=([0-9.]+)\s*$")
LABEL_RE = re.compile(r"^(Queue|Match|Total) stats:\s*$")


def parse_throughputs(path: Path) -> List[float]:
    """Every run's operations_per_sec in `path`, one value per run.

    Handles both file shapes:
      * V6A: three labelled blocks per run (Queue/Match/Total). All three share one
        batch span and one sample count, so operations_per_sec is IDENTICAL in all
        three -- we take Total for explicitness, not because it differs.
      * V5S: a single unlabelled block per run.
    """
    if not path.exists():
        return []

    runs: List[float] = []
    current_label: Optional[str] = None
    per_run: Dict[Optional[str], float] = {}

    def flush() -> None:
        if not per_run:
            return
        # Prefer the Total block; fall back to the sole unlabelled value (V5S).
        value = per_run.get("Total", next(iter(per_run.values())))
        runs.append(value)
        per_run.clear()

    for line in path.read_text().splitlines():
        line = line.strip()
        if line == "---":
            flush()
            current_label = None
            continue
        label_match = LABEL_RE.match(line)
        if label_match:
            current_label = label_match.group(1)
            continue
        ops_match = OPS_RE.match(line)
        if ops_match:
            per_run[current_label] = float(ops_match.group(1))
    flush()

    return runs


def harmonic(n: int, s: float) -> float:
    """Generalized harmonic number H(n, s) = sum_{k=1..n} 1/k^s."""
    return sum(1.0 / (k**s) for k in range(1, n + 1))


def ceilings(num_shards: int, zipf_exp: float) -> Dict[str, float]:
    """Predicted throughput ceiling per skew, as a multiple of mu."""
    return {
        "uniform": harmonic(num_shards, 0.0),      # == num_shards
        "zipf": harmonic(num_shards, zipf_exp),
        "one-hot": 1.0,
    }


def summarize(values: List[float]) -> Dict[str, float]:
    """Median + IQR half-widths, for the error bars."""
    median = statistics.median(values)
    if len(values) >= 4:
        q1, _, q3 = statistics.quantiles(values, n=4)
    else:
        q1 = q3 = median
    return {"median": median, "lo": median - q1, "hi": q3 - median}


def plot_one(
    prices: str,
    v5s: Dict[str, float],
    v6a: Dict[str, Dict[str, float]],
    caps: Dict[str, float],
    engine: str,
    num_shards: int,
    zipf_exp: float,
    n_runs: int,
    out_path: Path,
) -> None:
    labels = ["v5s\n(1 book, no queue)"] + [f"{engine} {s}\n({num_shards} shards)" for s in SKEWS]
    medians = [v5s["median"]] + [v6a[s]["median"] for s in SKEWS]
    err_lo = [v5s["lo"]] + [v6a[s]["lo"] for s in SKEWS]
    err_hi = [v5s["hi"]] + [v6a[s]["hi"] for s in SKEWS]
    colors = [C_V5S] + [C_V6A] * len(SKEWS)

    mu = v5s["median"]
    to_m = lambda v: v / 1e6  # noqa: E731  -- plot in millions of orders/sec

    fig, ax = plt.subplots(figsize=(9.0, 5.6))
    fig.patch.set_facecolor(C_SURFACE)
    ax.set_facecolor(C_SURFACE)

    x = range(len(labels))
    bars = ax.bar(
        x,
        [to_m(v) for v in medians],
        width=0.58,
        color=colors,
        yerr=[[to_m(v) for v in err_lo], [to_m(v) for v in err_hi]],
        ecolor=C_CEIL,
        capsize=4,
        zorder=3,
        label="_nolegend_",
    )

    # Predicted ceiling caps, mu * H(N, s), over the V6A bars only.
    cap_handle = None
    for i, skew in enumerate(SKEWS, start=1):
        cap = to_m(mu * caps[skew])
        left = bars[i].get_x()
        width = bars[i].get_width()
        (cap_handle,) = ax.plot(
            [left - 0.04, left + width + 0.04],
            [cap, cap],
            linestyle=(0, (4, 3)),
            linewidth=2.0,
            color=C_CEIL,
            zorder=5,
        )
        ax.annotate(
            f"ceiling {caps[skew]:.2f}μ",
            xy=(left + width + 0.06, cap),
            va="center",
            ha="left",
            fontsize=8.5,
            color=C_CEIL,
        )

    # Direct value labels: every bar gets its number, so identity is never colour-alone.
    # The label clears whichever is higher, the bar top or its ceiling cap — when a bar
    # nearly attains its ceiling the two are millimetres apart and would collide.
    for i, (bar, value) in enumerate(zip(bars, medians)):
        cap = to_m(mu * caps[SKEWS[i - 1]]) if i > 0 else 0.0
        ax.annotate(
            f"{to_m(value):.2f}M",
            xy=(bar.get_x() + bar.get_width() / 2, max(to_m(value), cap)),
            xytext=(0, 6),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=10,
            fontweight="bold",
            color=C_TEXT,
            zorder=6,
        )
        # Achieved multiple of mu, under the axis label.
        if i > 0:
            frac = value / mu
            attained = value / (mu * caps[SKEWS[i - 1]])
            ax.annotate(
                f"{frac:.2f}μ  ({attained:.0%} of ceiling)",
                xy=(bar.get_x() + bar.get_width() / 2, 0),
                xytext=(0, -34),
                textcoords="offset points",
                ha="center",
                va="top",
                fontsize=8.5,
                color=C_MUTED,
            )

    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=9.5, color=C_TEXT)
    ax.set_ylabel("throughput (millions of orders/sec)", fontsize=10, color=C_TEXT)
    ax.set_title(
        f"{engine} saturation throughput vs instrument skew — {prices.replace('_', ' ')} prices",
        fontsize=13,
        color=C_TEXT,
        pad=14,
        loc="left",
    )
    ax.annotate(
        f"median of {n_runs} runs, IQR error bars · μ = v5s median = {to_m(mu):.2f}M orders/sec · "
        f"ceiling = μ·H({num_shards}, s), zipf s={zipf_exp:g}",
        xy=(0, 1.015),
        xycoords="axes fraction",
        fontsize=8.5,
        color=C_MUTED,
    )

    ax.grid(axis="y", color=C_GRID, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color("#c3c2b7")
    ax.tick_params(axis="y", colors=C_MUTED, length=0)
    ax.tick_params(axis="x", colors=C_TEXT, length=0, pad=8)

    top = max([to_m(mu * c) for c in caps.values()] + [to_m(v) for v in medians])
    ax.set_ylim(0, top * 1.18)

    legend_handles = [
        plt.Rectangle((0, 0), 1, 1, color=C_V5S),
        plt.Rectangle((0, 0), 1, 1, color=C_V6A),
    ]
    legend_labels = ["v5s baseline (μ)", f"{engine} measured ({num_shards} shards)"]
    if cap_handle is not None:
        legend_handles.append(cap_handle)
        legend_labels.append("predicted ceiling μ·H(N, s)")
    ax.legend(
        legend_handles,
        legend_labels,
        frameon=False,
        fontsize=9,
        loc="upper right",
        labelcolor=C_TEXT,
    )

    fig.subplots_adjust(bottom=0.22)
    fig.savefig(out_path, dpi=160, facecolor=C_SURFACE, bbox_inches="tight")
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot V6A saturation throughput vs skew, against the V5S baseline."
    )
    parser.add_argument("--results-dir", default="results/multishard_throughput")
    parser.add_argument(
        "--baseline-dir",
        default=None,
        help="where the v5s_<prices>_mixed.txt stats files live "
             "(default: --results-dir, i.e. the mu the sweep measured in the same session)",
    )
    parser.add_argument("--engine", default="v6a",
                        help="v6a (MutexQueue+cv) | v6a_nb (NonblockingMutexQueue, spin)")
    parser.add_argument("--shards", type=int, default=3)
    parser.add_argument("--producers", type=int, default=3)
    parser.add_argument(
        "--zipf-exp",
        type=float,
        default=1.0,
        help="the s the testcases were generated with (default: 1.0)",
    )
    parser.add_argument("--output-dir", default=None, help="default: --results-dir")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    root = Path(__file__).resolve().parents[2]
    results_dir = root / args.results_dir
    # mu now comes from the sweep's OWN output by default: it is measured in the same
    # session, on a clean core, under the same bench controls. Falls back to the old
    # multithread_bench location only if the sweep did not write a baseline.
    if args.baseline_dir:
        baseline_dir = root / args.baseline_dir
    elif list(results_dir.glob("v5s_*_mixed.txt")):
        baseline_dir = results_dir
    else:
        baseline_dir = root / "results/multithread_bench"
        print(f"[warn] no v5s_*_mixed.txt in {results_dir}; falling back to {baseline_dir}.\n"
              f"       That file may be stale/cpu0-contaminated — re-run the sweep to "
              f"measure mu in-session.", file=sys.stderr)
    out_dir = root / (args.output_dir or args.results_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    caps = ceilings(args.shards, args.zipf_exp)
    label = f"{args.engine}_N{args.producers}_S{args.shards}"
    exit_code = 0

    for prices in PRICE_MODES:
        baseline_path = baseline_dir / f"v5s_{prices}_mixed.txt"
        baseline_runs = parse_throughputs(baseline_path)
        if not baseline_runs:
            print(
                f"[skip] {prices}: no v5s baseline at {baseline_path}\n"
                f"       run: ./experiments/multithread_bench/sweep.sh",
                file=sys.stderr,
            )
            exit_code = 1
            continue

        v6a: Dict[str, Dict[str, float]] = {}
        missing: List[str] = []
        n_runs = len(baseline_runs)
        for skew in SKEWS:
            stem = f"{label}_multi_{args.shards}_{skew}_{prices}"
            runs = parse_throughputs(results_dir / f"{stem}.txt")
            if not runs:
                missing.append(skew)
                continue
            v6a[skew] = summarize(runs)
            n_runs = min(n_runs, len(runs))

        if missing:
            print(
                f"[skip] {prices}: no v6a data for {', '.join(missing)}\n"
                f"       run: ./experiments/multishard_throughput/sweep.sh --engine {args.engine} "
                f"--shards {args.shards} --producers {args.producers}",
                file=sys.stderr,
            )
            exit_code = 1
            continue

        out_path = out_dir / f"throughput_{args.engine}_{prices}.png"
        plot_one(
            prices,
            summarize(baseline_runs),
            v6a,
            caps,
            args.engine,
            args.shards,
            args.zipf_exp,
            n_runs,
            out_path,
        )

        mu = statistics.median(baseline_runs)
        print(f"wrote {out_path}")
        print(f"  μ (v5s)      {mu / 1e6:8.3f}M orders/sec")
        for skew in SKEWS:
            got = v6a[skew]["median"]
            print(
                f"  {skew:<12} {got / 1e6:8.3f}M  =  {got / mu:5.2f}μ   "
                f"(ceiling {caps[skew]:.2f}μ, attained {got / (mu * caps[skew]):.0%})"
            )
        print()

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
