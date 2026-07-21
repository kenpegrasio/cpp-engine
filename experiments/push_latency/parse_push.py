#!/usr/bin/env python3
"""Summarize the push decomposition: PUSH against queue / match / total.

There is no separate push sweep — push/queue/match/total all come out of ONE engine
run, so this reads the stats files the multishard throughput sweep already writes
(experiments/multishard_throughput/sweep.sh -> results/multishard_throughput/). One
sweep, parsed two ways: plot_throughput.py for ops/sec, this for the push breakdown.

Each run emits FOUR key=value blocks — Push, Queue, Match, Total — and this script takes
the median-across-reps of each percentile, per testcase, and prints a table.

NOTE: only sweeps run AFTER the push BenchmarkRunner was added carry a Push block; older
stats files will show "push  —". Re-run the multishard sweep to populate it.

The story it exists to tell, per testcase:

    push    the producer's own cost: mutex acquire + enqueue + notify (FUTEX_WAKE).
            This is the MEASURED number that replaces the throughput/producer_count guess.
    queue   enqueue -> dequeue: the push cost PLUS queue-sit PLUS waking a sleeping consumer.
            queue - push  ~=  how long an order waits AFTER it was pushed (mostly wakeup).
    match   the actual matching, ~140 ns — the work the queue exists to feed.
    total   queue + match, the end-to-end sojourn.

Watch the push MEAN vs push p50: on a mutex queue the median push is cheap (most pushes
hit no registered waiter -> no syscall) while the mean is dragged up by the fraction that
fire a real FUTEX_WAKE. A big mean/median gap IS the notify tail.

Output: a table to stdout, and a tidy CSV (--csv, default results/push_latency/push_summary_<engine>.csv).

Usage:
    python3 experiments/push_latency/parse_push.py
    python3 experiments/push_latency/parse_push.py --engine v6a_nb
    python3 experiments/push_latency/parse_push.py --engines v6a v6a_nb   # side by side
    python3 experiments/push_latency/parse_push.py --results-dir results/multishard_throughput
"""

import argparse
import csv as csvmod
import re
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Optional

SKEWS = ["uniform", "zipf", "one-hot"]
PRICE_MODES = ["heavy_overlap", "wide_range"]
BLOCKS = ["Push", "Queue", "Match", "Total"]
# Metrics carried by every block, in the order they appear in the stats file.
METRICS = ["avg", "p50", "p95", "p99", "p99_9", "max"]

HEADER_RE = re.compile(r"^(Push|Queue|Match|Total) stats:\s*$")
KV_RE = re.compile(r"^([a-z0-9_]+)=([0-9.]+)\s*$")


def parse_file(path: Path) -> Dict[str, Dict[str, float]]:
    """Median-across-reps of every (block, metric) in one stats file.

    Returns {block: {metric: median_ns}}. A file holds N runs, each with the four
    blocks; we collect every rep's value per (block, metric) and take the median.
    """
    if not path.exists():
        return {}

    # samples[block][metric] = [value per rep]
    samples: Dict[str, Dict[str, List[float]]] = {b: {m: [] for m in METRICS} for b in BLOCKS}
    current: Optional[str] = None

    for line in path.read_text().splitlines():
        line = line.strip()
        if line == "---":
            current = None
            continue
        h = HEADER_RE.match(line)
        if h:
            current = h.group(1)
            continue
        if current is None:
            continue
        m = KV_RE.match(line)
        if not m:
            continue
        key, value = m.group(1), float(m.group(2))
        # keys look like "p50_latency_ns", "avg_latency_ns", "p99_9_latency_ns"
        if key.endswith("_latency_ns"):
            metric = key[: -len("_latency_ns")]
            if metric in samples[current]:
                samples[current][metric].append(value)

    out: Dict[str, Dict[str, float]] = {}
    for block in BLOCKS:
        block_out: Dict[str, float] = {}
        for metric in METRICS:
            vals = samples[block][metric]
            if vals:
                block_out[metric] = statistics.median(vals)
        if block_out:
            out[block] = block_out
    return out


def fmt(ns: Optional[float]) -> str:
    if ns is None:
        return "     —"
    if ns >= 1000:
        return f"{ns / 1000:6.2f}µs"
    return f"{ns:6.0f}ns"


def main() -> int:
    ap = argparse.ArgumentParser(description="Summarize the push-latency sweep.")
    ap.add_argument("--engine", default=None, help="single engine (default v6a)")
    ap.add_argument("--engines", nargs="+", default=None,
                    help="compare several, e.g. --engines v6a v6a_nb")
    ap.add_argument("--results-dir", default="results/multishard_throughput",
                    help="where the sweep's stats files live (the multishard sweep output)")
    ap.add_argument("--shards", type=int, default=3)
    ap.add_argument("--producers", type=int, default=3)
    ap.add_argument("--csv", default=None, help="tidy CSV out (default: <results>/push_summary_<engine>.csv)")
    args = ap.parse_args()

    engines = args.engines or [args.engine or "v6a"]
    root = Path(__file__).resolve().parents[2]
    results_dir = root / args.results_dir

    rows = []          # for CSV: dict per (engine, skew, prices, block)
    any_data = False

    for engine in engines:
        label = f"{engine}_N{args.producers}_S{args.shards}"
        print(f"\n=== {engine}  (N={args.producers}, S={args.shards})  —  median across reps ===")
        print(f"{'testcase':<26} {'block':<6} "
              + " ".join(f"{m:>8}" for m in ("avg", "p50", "p95", "p99", "p99.9", "max")))
        print("-" * 88)

        for skew in SKEWS:
            for prices in PRICE_MODES:
                stem = f"multi_{args.shards}_{skew}_{prices}"
                data = parse_file(results_dir / f"{label}_{stem}.txt")
                if not data:
                    print(f"{skew + '/' + prices:<26} {'—':<6} (no data — run the sweep)")
                    continue
                any_data = True
                for bi, block in enumerate(BLOCKS):
                    b = data.get(block, {})
                    name = f"{skew}/{prices}" if bi == 0 else ""
                    print(f"{name:<26} {block.lower():<6} "
                          + " ".join(fmt(b.get(m)) for m in METRICS))
                    rows.append({
                        "engine": engine, "skew": skew, "prices": prices,
                        "block": block.lower(),
                        **{m: b.get(m, "") for m in METRICS},
                    })
                # the one-line takeaway per cell: measured push vs the wakeup it hides
                push, queue, match = data.get("Push", {}), data.get("Queue", {}), data.get("Match", {})
                if push.get("p50") and push.get("avg"):
                    ratio = push["avg"] / push["p50"]
                    note = (f"    push p50={fmt(push['p50']).strip()} "
                            f"mean={fmt(push['avg']).strip()} (mean/median {ratio:.1f}× = notify tail)")
                    if queue.get("p50") and push.get("p50"):
                        note += f"   post-push wait≈{fmt(queue['p50'] - push['p50']).strip()}"
                    print(note)
                print()

    if not any_data:
        hint = "./experiments/multishard_throughput/sweep.sh"
        if len(engines) != 1 or engines[0] != "v6a":
            hint += " --engine <E>  (once per engine)"
        print(f"\n[error] no Push data in {results_dir} for {engines}\n"
              f"        run the sweep (its stats files now carry the Push block):\n"
              f"        {hint}",
              file=sys.stderr)
        return 1

    # Read from the sweep dir, but write the push analysis output to push_latency/ so it
    # does not mingle with the sweep's own files.
    csv_path = Path(args.csv) if args.csv else \
        Path("results/push_latency") / f"push_summary_{'_'.join(engines)}.csv"
    csv_path = root / csv_path if not csv_path.is_absolute() else csv_path
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="") as fh:
        w = csvmod.DictWriter(fh, fieldnames=["engine", "skew", "prices", "block", *METRICS])
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
