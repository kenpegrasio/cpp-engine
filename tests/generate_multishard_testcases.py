#!/usr/bin/env python3
"""Generate multi-shard (multi-instrument) matching-engine benchmark workloads.

Companion to generate_testcases.py, which produces single-shard files. This
script varies two independent workload axes (see the "Load Patterns" table in
CLAUDE.md -- they are orthogonal, do not conflate them).

Instrument skew, over *space* (which shard an order lands on). Controls the
per-shard load rho, i.e. how well the flow splits across shards:

    uniform  - every shard equally likely             (no-skew baseline)
    zipf     - shard of rank r drawn with p ~ 1/r^s   (few hot, many cold)
    one-hot  - every order targets a single shard      (maximal skew)

Price distribution, over *price levels* (what an order costs to match).
Controls the service time E[S] via the crossing rate. Both modes mirror
generate_testcases.py so single- and multi-shard runs are comparable:

    heavy_overlap - B in [95,110], S in [90,105]  (high crossing rate, deep
                    contention on a narrow band of levels)
    wide_range    - B and S both in [50,150]      (low crossing rate, orders
                    spread thin across ~100 price levels)

Output format (see tests/testcase_format.md and parseMultishardOrders in
include/parser.hpp):

    <number-of-shards>
    <shard-code-0>
    ...
    <shard-code-(N-1)>

    <number-of-orders>
    <order-id> <shard-code> <B|S> <quantity> <price>
    ...

The parser reads with `>>`, so the blank line above is cosmetic. Shard index is
the code's appearance order in the header; index 0 is the "hot" shard for zipf
and one-hot.

Reproducibility: all randomness comes from a single seeded random.Random, so a
given (skew, --shards, --count, --seed, --zipf-exp, --prices) always yields
identical bytes.

Examples:
    ./generate_multishard_testcases.py zipf --shards 2
        -> writes generated_multi_2_Zipf_heavy_overlap
    ./generate_multishard_testcases.py uniform --shards 4 --prices wide_range
        -> writes generated_multi_4_uniform_wide_range
    ./generate_multishard_testcases.py one-hot --shards 3 --output -
        -> writes to stdout
"""

import argparse
import random
import sys
from typing import List, TextIO, Tuple


# The V6A runner indexes its per-shard book/queue arrays by shard appearance
# order and those arrays are sized MAX_SHARDS (include/constants.hpp). Declaring
# more distinct shards than that reads out of bounds at runtime -- raise
# MAX_SHARDS and rebuild before generating more than this many shards.
ENGINE_MAX_SHARDS = 64

# Price bound the per-shard books can index: array<deque, MAX_PRICE + 1>, so any
# price in [0, MAX_PRICE] is safe (MAX_PRICE = 200 in include/constants.hpp).
MAX_PRICE = 200

# Human-readable filename suffix per skew (matches the requested naming).
SKEW_LABELS = {
    "uniform": "uniform",
    "zipf": "Zipf",
    "one-hot": "one-hot",
}

# Per-side price bounds, inclusive: (buy_lo, buy_hi, sell_lo, sell_hi). These are
# copied from generate_testcases.py's heavy_overlap_mixed / wide_range_mixed so a
# single-shard run and a 1-shard multishard run are the same workload. Every bound
# must stay within [0, MAX_PRICE].
PRICE_MODES = {
    "heavy_overlap": (95, 110, 90, 105),
    "wide_range": (50, 150, 50, 150),
}

# Readable instrument codes; index 0 is the hot shard for zipf / one-hot.
SHARD_CODE_POOL = ["AAPL", "MSFT", "NVDA", "TSLA", "AMZN", "META", "GOOG", "NFLX"]


def shard_code(index: int) -> str:
    if index < len(SHARD_CODE_POOL):
        return SHARD_CODE_POOL[index]
    return f"SYM{index}"


def shard_weights(num_shards: int, skew: str, zipf_exp: float) -> List[float]:
    """Un-normalised probability weight per shard index (0..num_shards-1).

    random.choices normalises internally, so weights need not sum to 1.
    """
    if skew == "uniform":
        return [1.0] * num_shards
    if skew == "one-hot":
        return [1.0] + [0.0] * (num_shards - 1)
    if skew == "zipf":
        # Finite (truncated) Zipf over exactly num_shards ranks: rank r = 1..N,
        # weight 1/r^s. This is deliberately NOT random.zipf, whose support is
        # the infinite set {1, 2, 3, ...} and would emit shard ids > N. Build
        # the finite weight vector explicitly instead.
        return [1.0 / (r ** zipf_exp) for r in range(1, num_shards + 1)]
    raise ValueError(f"unknown skew: {skew}")


def random_order_body(rng: random.Random, prices: str) -> Tuple[str, int, int]:
    """A mixed buy/sell order, priced per the chosen price-distribution mode.

    Hold this axis fixed across a skew sweep and vary only --skew; hold --skew
    fixed and vary this to move the crossing rate (and hence E[S]) instead.
    """
    buy_lo, buy_hi, sell_lo, sell_hi = PRICE_MODES[prices]
    quantity = rng.randint(1, 100)
    if rng.random() < 0.5:
        return "B", quantity, rng.randint(buy_lo, buy_hi)
    return "S", quantity, rng.randint(sell_lo, sell_hi)


def generate_multishard(
    out: TextIO,
    count: int,
    num_shards: int,
    skew: str,
    zipf_exp: float,
    prices: str,
    rng: random.Random,
) -> None:
    # Header: shard count, one code per line, blank line, then order count.
    out.write(f"{num_shards}\n")
    for i in range(num_shards):
        out.write(f"{shard_code(i)}\n")
    out.write("\n")
    out.write(f"{count}\n")

    population = list(range(num_shards))
    weights = shard_weights(num_shards, skew, zipf_exp)
    for order_id in range(1, count + 1):
        shard_index = rng.choices(population, weights=weights, k=1)[0]
        side, quantity, price = random_order_body(rng, prices)
        out.write(f"{order_id} {shard_code(shard_index)} {side} {quantity} {price}\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate multi-shard matching-engine benchmark workloads."
    )
    parser.add_argument(
        "skew",
        choices=sorted(SKEW_LABELS.keys()),
        help="Instrument skew distribution over shards.",
    )
    parser.add_argument(
        "--shards",
        type=int,
        default=2,
        help="Number of distinct shards (instruments) N. Default: 2",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=1_000_000,
        help="Number of orders to generate. Default: 1000000",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducible output. Default: 42",
    )
    parser.add_argument(
        "--zipf-exp",
        type=float,
        default=1.0,
        help="Zipf exponent s (p ~ 1/rank^s); only used for skew=zipf. Default: 1.0",
    )
    parser.add_argument(
        "--prices",
        choices=sorted(PRICE_MODES.keys()),
        default="heavy_overlap",
        help="Price distribution per order, mirroring generate_testcases.py. "
        "Default: heavy_overlap",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output file path. Use '-' for stdout. "
        "Default: generated_multi_<N>_<skew>_<prices>",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.count <= 0:
        raise ValueError("--count must be positive")
    if args.shards < 1:
        raise ValueError("--shards must be at least 1")
    if args.skew == "zipf" and args.zipf_exp < 0:
        raise ValueError("--zipf-exp must be non-negative")

    if args.shards > ENGINE_MAX_SHARDS:
        print(
            f"warning: --shards {args.shards} exceeds the engine's MAX_SHARDS "
            f"({ENGINE_MAX_SHARDS} in include/constants.hpp); the V6A runner "
            f"will read out of bounds unless you raise MAX_SHARDS and rebuild.",
            file=sys.stderr,
        )

    rng = random.Random(args.seed)

    label = SKEW_LABELS[args.skew]
    output = args.output
    if output is None:
        output = f"generated_multi_{args.shards}_{label}_{args.prices}"

    if output == "-":
        generate_multishard(
            sys.stdout,
            args.count,
            args.shards,
            args.skew,
            args.zipf_exp,
            args.prices,
            rng,
        )
        return 0

    with open(output, "w", encoding="ascii", newline="\n") as out:
        generate_multishard(
            out,
            args.count,
            args.shards,
            args.skew,
            args.zipf_exp,
            args.prices,
            rng,
        )
    print(
        f"wrote {args.count} orders across {args.shards} shards "
        f"({args.skew}, {args.prices}) to {output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
