#!/usr/bin/env python3
"""
Roll up `perf annotate --stdio --source` output into per-source-line cycle
attribution for insertOrder + matchOrders, across engines × workloads.

The raw .annot.txt files are interleaved source + assembly. Each block of
the form `: NN  source text` sets the current source line, and the following
assembly lines `XX.XX :  ADDR:  asm` add XX.XX% to that line. We accumulate
those percentages per (source line, source text) so you see the cost of each
C++ expression rather than per-instruction asm noise.

For each workload + function we print one table per engine, sorted by
descending cycle %, showing the source line + cumulative %. Lines from
inlined libstdc++ headers are kept by default (they ARE real work and the
caller usually wants to see e.g. _Rb_tree internals); pass --user-only to
restrict to lines in src/*.

Run from anywhere:
    python3 experiments/instruction_attribution/summarize.py
    python3 experiments/instruction_attribution/summarize.py --top 8 --user-only
"""

import argparse
import re
from collections import defaultdict
from pathlib import Path

ENGINES = ["v1", "v2", "v3"]
FUNCTIONS = ["insertOrder", "matchOrders"]

# `: 16  if (order.order_side == OrderSide::Buy)`
# `: 16   <text>`  →  group(1)=16  group(2)="<text>"
SRC_LINE_RE = re.compile(r"^\s*:\s*(\d+)\s+(.*)$")

# `   11.05 :  4134:  mov  ...`   or   `    0.00 :  4136:  jmp  ...`
ASM_PCT_RE = re.compile(r"^\s*(\d+\.\d+)\s*:\s*[0-9a-f]+:\s")

# Disassembly section / annotate header lines we want to skip when looking
# for "the first interesting source line."
HEADER_RE = re.compile(r"^\s*:\s*\d+\s+(Disassembly of section|0x[0-9a-f]+\s*<)")

# A path inside libstdc++ / glibc headers (everything in /usr/include or
# bits/, etc.). We don't always know the file path from perf annotate's
# interleaved view, so this is best-effort: source lines that mention
# `<stl_`, `<bits/`, `<deque>`, `<map>`, etc. as their context.
# In practice, `--source` already inlines the source text without a path,
# so we filter by source content heuristics in is_user_line().


def is_user_line(text: str) -> bool:
    """Heuristic: is this source line from src/engine_*.cpp (vs an inlined
    libstdc++ header)?

    perf annotate doesn't print file paths in the interleaved view — only the
    source text. Engine source lines reference user identifiers like `bids`,
    `asks`, `order`, `matchOrders`, etc. Inlined libstdc++ lines tend to
    reference STL implementation details (`_M_`, `__normal_iterator`,
    `_Rb_tree_node`, `this->_M_impl`, etc.) and use the C++ template/STL
    naming style.
    """
    if not text.strip():
        return False
    stl_markers = ("_M_", "_Rb_tree_", "_Deque_", "_S_", "__gnu_cxx",
                   "this->_M_", "_GLIBCXX", "__cplusplus")
    return not any(m in text for m in stl_markers)


def parse_annot(path: Path) -> list[tuple[int, str, float]]:
    """Return list of (line_no, source_text, pct) accumulated per source line.

    A given source line can appear multiple times in the perf output (the
    optimizer interleaves asm across source lines); we sum all percentages
    that landed on a given (line_no, source_text) into one entry. Result is
    deduplicated and sorted by descending pct.
    """
    if not path.exists():
        return []

    # (line_no, source_text) → cumulative pct
    bucket: dict[tuple[int, str], float] = defaultdict(float)
    current_key: tuple[int, str] | None = None
    total_samples = 0

    with path.open() as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            # New source-line marker resets the "current" attribution target
            sm = SRC_LINE_RE.match(line)
            if sm and not HEADER_RE.match(line):
                ln = int(sm.group(1))
                text = sm.group(2).rstrip()
                current_key = (ln, text)
                continue
            # Assembly line with percent → add to current source line
            am = ASM_PCT_RE.match(line)
            if am and current_key is not None:
                try:
                    pct = float(am.group(1))
                except ValueError:
                    continue
                bucket[current_key] += pct
                total_samples += 1

    rows = [(ln, text, pct) for (ln, text), pct in bucket.items() if pct > 0.0]
    rows.sort(key=lambda r: r[2], reverse=True)
    return rows


RAW_RE = re.compile(r"^(v\d)_(.+)_(insertOrder|matchOrders)\.annot\.txt$")


def discover(input_dir: Path) -> dict[tuple[str, str], dict[str, Path]]:
    """Return {(workload, function): {engine: path}} for all annot files."""
    out: dict[tuple[str, str], dict[str, Path]] = defaultdict(dict)
    for f in input_dir.glob("v*_*_*.annot.txt"):
        m = RAW_RE.match(f.name)
        if not m:
            continue
        engine, workload, func = m.group(1), m.group(2), m.group(3)
        if engine not in ENGINES or func not in FUNCTIONS:
            continue
        out[(workload, func)][engine] = f
    return out


def truncate(s: str, w: int) -> str:
    if len(s) <= w:
        return s
    return s[: w - 1] + "…"


def render(workload: str, func: str,
           engine_files: dict[str, Path],
           top_n: int, user_only: bool, src_width: int) -> None:
    header = f"=== {workload}  /  {func} "
    print(f"\n{header}{'=' * max(0, 70 - len(header))}")

    for engine in ENGINES:
        path = engine_files.get(engine)
        if path is None:
            print(f"\n  [{engine}]  (no annotation file)")
            continue

        rows = parse_annot(path)
        if user_only:
            rows = [r for r in rows if is_user_line(r[1])]

        if not rows:
            print(f"\n  [{engine}]  (no samples — function likely never ran "
                  f"or was inlined)")
            continue

        total_pct = sum(p for _l, _t, p in rows)
        shown = rows[:top_n]

        print(f"\n  [{engine}]   {path.name}   "
              f"(top {len(shown)} of {len(rows)} source lines, "
              f"sum of shown = {sum(p for _l, _t, p in shown):.1f}% of "
              f"{total_pct:.1f}% function total)")
        print(f"    {'pct':>7}  {'line':>5}  source")
        print(f"    {'-' * 7}  {'-' * 5}  {'-' * src_width}")
        for ln, text, pct in shown:
            print(f"    {pct:>6.2f}%  {ln:>5}  {truncate(text, src_width)}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Per-source-line cycle attribution for insertOrder + matchOrders.")
    default_in = (Path(__file__).resolve().parent.parent.parent
                  / "results" / "instruction_attribution")
    parser.add_argument("--input-dir", default=str(default_in),
                        help="dir with <engine>_<workload>_<func>.annot.txt files "
                             "(default: results/instruction_attribution)")
    parser.add_argument("--top", type=int, default=10,
                        help="how many source lines per (engine, function, workload) "
                             "(default: 10)")
    parser.add_argument("--user-only", action="store_true",
                        help="hide inlined libstdc++ source lines (keep only "
                             "src/engine_*.cpp-style lines, by heuristic)")
    parser.add_argument("--src-width", type=int, default=96,
                        help="column width for the source-text column (default: 96)")
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    discovered = discover(input_dir)
    if not discovered:
        print(f"[error] no annotation files found in {input_dir}")
        print("        run: experiments/instruction_attribution/bench_sweep.sh")
        return 1

    # Sort by workload first, then function — so each workload's two
    # functions (insertOrder, matchOrders) print together.
    for (workload, func) in sorted(discovered):
        render(workload, func, discovered[(workload, func)],
               args.top, args.user_only, args.src_width)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
