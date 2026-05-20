#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="$SCRIPT_DIR/generate_testcases.py"
OUTPUT_DIR="$SCRIPT_DIR/generated"

WORKLOADS=(
  "all_buy"
  "all_sell"
  "unmatched_mixed"
  "heavy_overlap_mixed"
  "wide_range_mixed"
)

COUNT=1000000

mkdir -p "$OUTPUT_DIR"

for workload in "${WORKLOADS[@]}"; do
  output_file="$OUTPUT_DIR/${workload}.txt"
  echo "Generating $output_file with seed=42"
  python3 "$GENERATOR" "$workload" --count "$COUNT" --seed 42 --output "$output_file"
done
