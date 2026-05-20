#!/usr/bin/env python3

import argparse
import random
import sys
from typing import TextIO


def write_header(out: TextIO, count: int) -> None:
    out.write(f"{count}\n")


def write_order(out: TextIO, order_id: int, side: str, quantity: int, price: int) -> None:
    out.write(f"{order_id} {side} {quantity} {price}\n")


def generate_all_buy(out: TextIO, count: int, rng: random.Random) -> None:
    write_header(out, count)
    for order_id in range(1, count + 1):
        quantity = rng.randint(1, 100)
        price = rng.randint(100, 200)
        write_order(out, order_id, "B", quantity, price)


def generate_all_sell(out: TextIO, count: int, rng: random.Random) -> None:
    write_header(out, count)
    for order_id in range(1, count + 1):
        quantity = rng.randint(1, 100)
        price = rng.randint(100, 200)
        write_order(out, order_id, "S", quantity, price)


def generate_unmatched_mixed(out: TextIO, count: int, rng: random.Random) -> None:
    write_header(out, count)
    for order_id in range(1, count + 1):
        quantity = rng.randint(1, 100)
        if order_id % 2 == 1:
            price = rng.randint(80, 99)
            write_order(out, order_id, "B", quantity, price)
        else:
            price = rng.randint(101, 120)
            write_order(out, order_id, "S", quantity, price)


def generate_heavy_overlap_mixed(out: TextIO, count: int, rng: random.Random) -> None:
    write_header(out, count)
    for order_id in range(1, count + 1):
        quantity = rng.randint(1, 100)
        side = "B" if rng.random() < 0.5 else "S"
        if side == "B":
            price = rng.randint(95, 110)
        else:
            price = rng.randint(90, 105)
        write_order(out, order_id, side, quantity, price)


def generate_wide_range_mixed(out: TextIO, count: int, rng: random.Random) -> None:
    write_header(out, count)
    for order_id in range(1, count + 1):
        quantity = rng.randint(1, 100)
        side = "B" if rng.random() < 0.5 else "S"
        if side == "B":
            price = rng.randint(50, 150)
        else:
            price = rng.randint(50, 150)
        write_order(out, order_id, side, quantity, price)


GENERATORS = {
    "all_buy": generate_all_buy,
    "all_sell": generate_all_sell,
    "unmatched_mixed": generate_unmatched_mixed,
    "heavy_overlap_mixed": generate_heavy_overlap_mixed,
    "wide_range_mixed": generate_wide_range_mixed,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate matching-engine benchmark workloads."
    )
    parser.add_argument(
        "workload",
        choices=sorted(GENERATORS.keys()),
        help="Workload type to generate.",
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
        "--output",
        type=str,
        default="-",
        help="Output file path. Use '-' for stdout. Default: -",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.count <= 0:
        raise ValueError("--count must be positive")

    rng = random.Random(args.seed)
    generator = GENERATORS[args.workload]

    if args.output == "-":
        generator(sys.stdout, args.count, rng)
        return 0

    with open(args.output, "w", encoding="ascii", newline="\n") as out:
        generator(out, args.count, rng)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
