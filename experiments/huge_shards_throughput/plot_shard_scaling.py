#!/usr/bin/env python3
"""Throughput vs shard (instrument) count — Design A rises, Design B is capped.

THE FIGURE

  x = number of shards/books B (log2)      y = throughput / mu
  one line per engine, plus the balls-in-bins prediction for the lock-based engine.

  v6a  (Design B: ownership + queue)  every order is PUSHED across a shard boundary.
       Push mean ~1.76us vs a ~144ns match, so V6A is HANDOFF-bound: more books cannot
       help, because every order still pays exactly one push. Its line is also SHORT --
       each book needs an owning thread, so B <= cores - producers. That truncation is
       a result, not missing data: Design B cannot express "64 instruments on 4 cores".

  v6b  (Design A: per-book lock)      no queue; a thread locks the book it needs.
       CONTENTION-bound, and contention falls as books spread the threads out, so the
       line RISES with B. Books are decoupled from threads (shard_count sizes arrays,
       not the pool), so it runs to MAX_SHARDS.

THE MODEL LINE

  With T threads picking uniformly among B books, the expected number of DISTINCT books
  in play is B*(1-(1-1/B)^T), so parallel efficiency is that over T. Scaled by the
  engine's own single-thread rate this is the contention-only ceiling for Design A.
  It ignores futex wakeup cost and cache traffic, so measurements are expected to fall
  BELOW it -- and the size of that gap is the interesting part, because it is everything
  contention alone does not explain.

INPUT   results/huge_shards_throughput/<engine>_N<N>_S<B>_<skew>_<prices>.txt
        results/huge_shards_throughput/v5s_<prices>_mixed.txt      (mu, measured in-session)

OUTPUT  results/huge_shards_throughput/shard_scaling_<skew>_<prices>.png

USAGE
    ./experiments/huge_shards_throughput/sweep.sh
    python3 experiments/huge_shards_throughput/plot_shard_scaling.py
    python3 experiments/huge_shards_throughput/plot_shard_scaling.py --engines v6a v6b --producers 2
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

# Palette: categorical slots in their documented order (that ordering IS the CVD-safety
# mechanism). Ink tokens carry all text, so no label ever wears its series colour.
SERIES = ["#2a78d6", "#1baf7a", "#eda100", "#008300"]   # blue, aqua, yellow, green
C_MODEL = "#898781"    # muted: the theoretical line is a reference, not a peer series
C_RULE = "#52514e"
C_TEXT = "#0b0b0b"
C_MUTED = "#898781"
C_GRID = "#e1e0d9"
C_SURFACE = "#fcfcfb"

OPS_RE = re.compile(r"^operations_per_sec=([0-9.]+)\s*$")

# How each engine's thread count relates to its shard count — mirrors worker_count_for()
# in sweep.sh. Used only to annotate WHY a line stops where it does.
QUEUE_BASED = {"v6a", "v6a_nb", "v6a_static"}


def median_throughput(path: Path) -> Optional[float]:
    """Median operations_per_sec across reps.

    Every labelled block in a run (Push/Queue/Match/Total) carries the SAME
    operations_per_sec — one batch span, one sample count — so taking all occurrences
    and then the median is exact, not a choice about which block to trust.
    """
    if not path.exists():
        return None
    vals = [float(m.group(1)) for line in path.read_text().splitlines()
            if (m := OPS_RE.match(line.strip()))]
    return statistics.median(vals) if vals else None


def expected_distinct(b: int, t: int) -> float:
    """E[distinct books in play] = B*(1-(1-1/B)^T) — the balls-in-bins model."""
    return b * (1.0 - (1.0 - 1.0 / b) ** t)


def plot_one(skew: str, prices: str, mu: float, data: Dict[str, Dict[int, float]],
             engines: List[str], shard_list: List[int], producers: int,
             out_path: Path) -> None:
    fig, ax = plt.subplots(figsize=(9.6, 6.0))
    fig.patch.set_facecolor(C_SURFACE)
    ax.set_facecolor(C_SURFACE)

    # ---- measured series -------------------------------------------------
    for i, engine in enumerate(engines):
        pts = sorted((b, v) for b, v in data.get(engine, {}).items())
        if not pts:
            continue
        xs = [b for b, _ in pts]
        ys = [v / mu for _, v in pts]
        ax.plot(xs, ys, marker="o", markersize=8, linewidth=2.2,
                color=SERIES[i], markeredgecolor=C_SURFACE, markeredgewidth=1.8,
                label=engine, zorder=4)
        # Label the last point of a truncated line with WHY it stops. A line that just
        # ends looks like missing data; this says it is a structural limit.
        if engine in QUEUE_BASED and xs[-1] < max(shard_list):
            ax.annotate(f"stops at B={xs[-1]}\n(needs {producers}+B threads;\n"
                        f"every book needs an owner)",
                        xy=(xs[-1], ys[-1]), xytext=(12, -6),
                        textcoords="offset points", fontsize=8.5,
                        color=SERIES[i], va="top",
                        arrowprops=dict(arrowstyle="-", color=SERIES[i], lw=1.0))

    # ---- balls-in-bins model for the lock-based engine --------------------
    # Anchored on that engine's own smallest-B measurement so it is a shape comparison,
    # not an absolute claim: efficiency(B)/efficiency(B0) x measured(B0).
    lock_engines = [e for e in engines if e not in QUEUE_BASED and data.get(e)]
    if lock_engines:
        e = lock_engines[0]
        pts = sorted(data[e].items())
        b0, v0 = pts[0]
        eff0 = expected_distinct(b0, producers) / producers
        xs = sorted(shard_list)
        ys = [(expected_distinct(b, producers) / producers) / eff0 * (v0 / mu) for b in xs]
        ax.plot(xs, ys, linestyle=(0, (5, 3)), linewidth=1.8, color=C_MODEL, zorder=3,
                label=f"contention-only model ({e})")

    # ---- mu reference ----------------------------------------------------
    ax.axhline(1.0, color=C_RULE, linewidth=1.6, zorder=2)
    ax.annotate("μ = one thread, one book, no queue",
                xy=(0.012, 1.0), xycoords=("axes fraction", "data"),
                xytext=(0, 5), textcoords="offset points",
                fontsize=8.5, color=C_RULE, va="bottom")

    ax.set_xscale("log", base=2)
    ax.set_xticks(sorted(shard_list))
    ax.set_xticklabels([str(b) for b in sorted(shard_list)])
    ax.set_xlabel("shards / instruments (books)  —  log₂ scale", fontsize=10, color=C_TEXT)
    ax.set_ylabel("throughput ÷ μ", fontsize=10, color=C_TEXT)
    ax.set_title(f"Throughput vs instrument count — {skew}, {prices.replace('_', ' ')} prices",
                 fontsize=13, color=C_TEXT, pad=14, loc="left")
    ax.annotate(f"N={producers} producer/worker threads · μ = v5s measured in-session · "
                f"queue-based engines are capped at B ≤ cores−N",
                xy=(0, 1.015), xycoords="axes fraction", fontsize=8.5, color=C_MUTED)

    ax.grid(color=C_GRID, linewidth=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("bottom", "left"):
        ax.spines[side].set_color("#c3c2b7")
    ax.tick_params(colors=C_MUTED, length=0)
    peak = max([v / mu for eng in data.values() for v in eng.values()] + [1.0])
    ax.set_ylim(0, peak * 1.18)   # headroom so the mu label clears the top
    ax.legend(frameon=False, fontsize=9, loc="lower right", labelcolor=C_TEXT)

    fig.savefig(out_path, dpi=160, facecolor=C_SURFACE, bbox_inches="tight")
    plt.close(fig)


def main() -> int:
    p = argparse.ArgumentParser(description="Plot throughput vs shard count.")
    p.add_argument("--engines", nargs="+", default=["v6a", "v6b"])
    p.add_argument("--shards", nargs="+", type=int, default=[2, 3, 4, 8, 16, 32, 64])
    p.add_argument("--skews", nargs="+", default=["uniform"])
    p.add_argument("--prices", nargs="+", default=["wide_range"])
    p.add_argument("--producers", type=int, default=2)
    p.add_argument("--results-dir", default="results/huge_shards_throughput")
    p.add_argument("--output-dir", default=None, help="default: --results-dir")
    args = p.parse_args()

    root = Path(__file__).resolve().parents[2]
    results_dir = root / args.results_dir
    out_dir = root / (args.output_dir or args.results_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    rc = 0

    for skew in args.skews:
        for prices in args.prices:
            mu_runs = median_throughput(results_dir / f"v5s_{prices}_mixed.txt")
            if mu_runs is None:
                print(f"[error] no baseline v5s_{prices}_mixed.txt in {results_dir}\n"
                      f"        run: ./experiments/huge_shards_throughput/sweep.sh",
                      file=sys.stderr)
                rc = 1
                continue

            data: Dict[str, Dict[int, float]] = {}
            for engine in args.engines:
                for b in args.shards:
                    f = results_dir / f"{engine}_N{args.producers}_S{b}_{skew}_{prices}.txt"
                    v = median_throughput(f)
                    if v is not None:
                        data.setdefault(engine, {})[b] = v

            if not data:
                print(f"[error] no engine data for {skew}/{prices} in {results_dir}",
                      file=sys.stderr)
                rc = 1
                continue

            out = out_dir / f"shard_scaling_{skew}_{prices}.png"
            plot_one(skew, prices, mu_runs, data, args.engines, args.shards,
                     args.producers, out)
            print(f"wrote {out}")
            print(f"  μ = {mu_runs / 1e6:.2f}M orders/sec")
            for engine in args.engines:
                pts = sorted(data.get(engine, {}).items())
                if not pts:
                    print(f"  {engine:<8} (no data)")
                    continue
                cells = "  ".join(f"B={b}:{v / mu_runs:.2f}μ" for b, v in pts)
                note = ""
                if engine in QUEUE_BASED and pts[-1][0] < max(args.shards):
                    note = f"   [capped: needs {args.producers}+B threads]"
                print(f"  {engine:<8} {cells}{note}")
            print()

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
