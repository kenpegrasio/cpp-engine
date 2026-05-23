#!/usr/bin/env python3
"""
compare_runs.py — compare multirun benchmark results as a terminal table.

Each row is one metric.  Each column is one engine.
Each cell shows:  median  (Q1 – Q3)
The best value per row is highlighted in green.

Usage:
    python3 scripts/compare_runs.py results/v1_heavy.txt results/v2_heavy.txt
    python3 scripts/compare_runs.py results/v1.txt results/v2.txt results/v3.txt --labels v1 v2 v3
    python3 scripts/compare_runs.py results/v1.txt results/v2.txt --no-color
"""

import argparse
import sys
from pathlib import Path

import numpy as np


# ---------------------------------------------------------------------------
# Metrics: (file_key, display_label, lower_is_better)
# ---------------------------------------------------------------------------
LATENCY_METRICS = [
    ("min_latency_ns",    "Min Latency (ns)",    True),
    ("avg_latency_ns",    "Avg Latency (ns)",    True),
    ("p50_latency_ns",    "p50 Latency (ns)",    True),
    ("p95_latency_ns",    "p95 Latency (ns)",    True),
    ("p99_latency_ns",    "p99 Latency (ns)",    True),
    ("p99_9_latency_ns",  "p99.9 Latency (ns)",  True),
    ("max_latency_ns",    "Max Latency (ns)",    True),
]

THROUGHPUT_METRICS = [
    ("operations_per_sec", "Throughput (ops/sec)", False),
    ("elapsed_ms",         "Elapsed Time (ms)",    True),
]

NOISE_RATIOS = [
    ("p99_9_latency_ns", "p50_latency_ns", "p99.9 / p50"),
    ("max_latency_ns",   "p50_latency_ns", "max / p50   "),
]

ALL_METRICS = LATENCY_METRICS + THROUGHPUT_METRICS


# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------
GREEN  = "\033[32;1m"
DIM    = "\033[2m"
RESET  = "\033[0m"


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
def parse_run_file(path: Path) -> dict[str, list[float]]:
    raw    = path.read_text()
    blocks = [b.strip() for b in raw.split("---") if b.strip()]
    out: dict[str, list[float]] = {}
    for block in blocks:
        for line in block.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            try:
                out.setdefault(key.strip(), []).append(float(val.strip()))
            except ValueError:
                pass
    return out


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------
def stats(values: list[float]) -> tuple[float, float, float]:
    """Return (median, Q1, Q3)."""
    a = np.array(values, dtype=float)
    return float(np.median(a)), float(np.percentile(a, 25)), float(np.percentile(a, 75))


def noise_ratio(num_vals: list[float], den_vals: list[float]) -> float:
    """Per-run ratio, then median."""
    n = np.array(num_vals, dtype=float)
    d = np.array(den_vals, dtype=float)
    return float(np.nanmedian(n / np.where(d > 0, d, np.nan)))


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
def fmt(v: float) -> str:
    if v >= 1_000_000:
        return f"{v / 1_000_000:.2f}M"
    if v >= 1_000:
        return f"{v / 1_000:.1f}k"
    if v >= 1:
        return f"{v:.1f}"
    return f"{v:.3f}"


def cell(median: float, q1: float, q3: float) -> str:
    """Format one table cell: 'median  (Q1 – Q3)'."""
    return f"{fmt(median):>8}  ({fmt(q1)} – {fmt(q3)})"


# ---------------------------------------------------------------------------
# Table drawing
# ---------------------------------------------------------------------------
def draw_table(
    labels:    list[str],
    file_data: list[dict[str, list[float]]],
    use_color: bool,
) -> None:
    n = len(labels)

    # Measure column widths from content
    label_col = 22                                    # metric name column
    val_cols  = [max(len(lbl) + 2, 22) for lbl in labels]  # per-engine columns

    # Box-drawing helpers
    def hline(left, mid, right, fill="─"):
        parts = [fill * (label_col + 2)]
        for w in val_cols:
            parts.append(fill * (w + 2))
        return left + mid.join(parts) + right

    def row(label: str, cells: list[str], highlights: list[bool]) -> str:
        padded_label = f" {label:<{label_col}} "
        parts = [padded_label]
        for i, (c, best) in enumerate(zip(cells, highlights)):
            w   = val_cols[i]
            txt = f" {c:<{w}} "
            if best and use_color:
                txt = f" {GREEN}{c:<{w}}{RESET} "
            parts.append(txt)
        return "│" + "│".join(parts) + "│"

    def dim(s: str) -> str:
        return f"{DIM}{s}{RESET}" if use_color else s

    # ── Header ──────────────────────────────────────────────────────────────
    print(hline("┌", "┬", "┐"))

    header_cells = [f" {'Metric':<{label_col}} "]
    for lbl, w in zip(labels, val_cols):
        header_cells.append(f" {lbl:^{w}} ")
    print("│" + "│".join(header_cells) + "│")

    n_runs = len(next(iter(file_data[0].values()), []))
    run_note = dim(f" {n_runs} runs each ")
    print("│" + f" {'':^{label_col}} " + "│".join(f" {run_note:^{w}} " for w in val_cols) + "│")

    # ── Latency section ─────────────────────────────────────────────────────
    print(hline("├", "┼", "┤"))

    for key, label, lower_is_better in LATENCY_METRICS:
        row_cells  = []
        row_medians = []
        for data in file_data:
            if key in data:
                m, q1, q3 = stats(data[key])
                row_cells.append(cell(m, q1, q3))
                row_medians.append(m)
            else:
                row_cells.append("N/A")
                row_medians.append(float("inf") if lower_is_better else float("-inf"))

        if row_medians:
            best_val   = min(row_medians) if lower_is_better else max(row_medians)
            highlights = [abs(v - best_val) < 1e-9 for v in row_medians]
        else:
            highlights = [False] * n

        print(row(label, row_cells, highlights))

    # ── Throughput section ───────────────────────────────────────────────────
    print(hline("├", "┼", "┤"))

    for key, label, lower_is_better in THROUGHPUT_METRICS:
        row_cells   = []
        row_medians = []
        for data in file_data:
            if key in data:
                m, q1, q3 = stats(data[key])
                row_cells.append(cell(m, q1, q3))
                row_medians.append(m)
            else:
                row_cells.append("N/A")
                row_medians.append(float("inf") if lower_is_better else float("-inf"))

        if row_medians:
            best_val   = min(row_medians) if lower_is_better else max(row_medians)
            highlights = [abs(v - best_val) < 1e-9 for v in row_medians]
        else:
            highlights = [False] * n

        print(row(label, row_cells, highlights))

    # ── Noise ratios ─────────────────────────────────────────────────────────
    print(hline("├", "┼", "┤"))

    for num_key, den_key, label in NOISE_RATIOS:
        row_cells  = []
        row_ratios = []
        for data in file_data:
            if num_key in data and den_key in data:
                r = noise_ratio(data[num_key], data[den_key])
                row_cells.append(f"{r:>8.2f}×")
                row_ratios.append(r)
            else:
                row_cells.append("N/A")
                row_ratios.append(float("inf"))

        best_val   = min(row_ratios)
        highlights = [abs(v - best_val) < 1e-9 for v in row_ratios]
        print(row(label, row_cells, highlights))

    # ── Transactions ─────────────────────────────────────────────────────────
    print(hline("├", "┼", "┤"))

    tx_cells = []
    for data in file_data:
        if "transactions" in data:
            tx_cells.append(f"{int(data['transactions'][0]):>8,}")
        else:
            tx_cells.append("N/A")
    print(row("Transactions (fixed)", tx_cells, [False] * n))

    print(hline("└", "┴", "┘"))

    if use_color:
        print(f"  {GREEN}■{RESET} = best in row")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Compare multirun benchmark files as a terminal table."
    )
    ap.add_argument(
        "files", nargs="+", metavar="FILE",
        help="Multirun output files (one per engine)",
    )
    ap.add_argument(
        "--labels", nargs="+", metavar="LABEL",
        help="Column labels (defaults to filename stems)",
    )
    ap.add_argument(
        "--no-color", action="store_true",
        help="Disable ANSI color highlighting",
    )
    args = ap.parse_args()

    paths  = [Path(f) for f in args.files]
    labels = args.labels or [p.stem for p in paths]

    for p in paths:
        if not p.is_file():
            print(f"[error] not found: {p}", file=sys.stderr)
            return 1
    if len(labels) != len(paths):
        print(f"[error] --labels count must match files count", file=sys.stderr)
        return 1

    use_color = not args.no_color and sys.stdout.isatty()

    file_data: list[dict[str, list[float]]] = []
    for label, path in zip(labels, paths):
        data = parse_run_file(path)
        if not data:
            print(f"[warn] no data in {path}", file=sys.stderr)
        n = len(next(iter(data.values()), []))
        print(f"  {label}: {n} runs  ← {path}", file=sys.stderr)
        file_data.append(data)

    print(file=sys.stderr)
    draw_table(labels, file_data, use_color)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
