#!/usr/bin/env bash
#
# Generate the full cross-product of multishard workloads into generated_shards/:
#
#   shards                x  skew                    x  prices
#   2,3,4,8,16,32,64         uniform, zipf, one-hot      heavy_overlap, wide_range
#
# = 7 x 3 x 2 = 42 files, named multi_<shards>_<skew>_<prices>.txt
#
# shards=1 is deliberately excluded: at N=1 all three skews collapse to the same
# weight vector [1.0] and produce byte-identical files, and the single-shard
# workload is already covered by generate_bulk_testcases.sh.
#
# WHY THE SHARD SWEEP GOES TO 64
#
# It is the x-axis of the Design A vs Design B study. Per-book locking (Design A,
# round-robin split -> every thread touches every book) is contention-bound when
# threads outnumber books: with T threads over B books the expected number of books
# in play is B*(1-(1-1/B)^T), so parallel efficiency is
#
#     B=2  -> 47%      B=8  -> 83%      B=32 -> 95%      (at T=4)
#     B=4  -> 68%      B=16 -> 91%      B=64 -> 98%
#
# so Design A should rise along this curve and asymptote toward Design B (per-shard
# split -> each book has one owner), which is flat in B once B >= T. The closing gap
# IS the result. Past 64 the curve is flat (98% -> 99%), so 64 is where it ends.
#
# CAPS, both real:
#   * MAX_SHARDS (include/constants.hpp) must be >= the largest shard count here, and
#     it sizes std::array members of engines that are STACK LOCALS in the runners'
#     main(): 64 books x 32KB = ~2MB against an 8MB default stack. 128 would be 4MB
#     (half the stack) and 256 would overflow it.
#   * Build ONCE at the final MAX_SHARDS and vary B via the testcase/--shard flag.
#     Changing MAX_SHARDS changes sizeof(EngineV6*) and therefore the memory layout,
#     so numbers taken at different MAX_SHARDS are not strictly comparable.
#
# Disk: 42 files x ~25MB = ~1.1GB. Use --shards to generate a subset if that is tight.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="$SCRIPT_DIR/generate_multishard_testcases.py"
OUTPUT_DIR="$SCRIPT_DIR/generated_shards"

SHARDS=(2 3 4 8 16 32 64)
SKEWS=("uniform" "zipf" "one-hot")
PRICES=("heavy_overlap" "wide_range")

COUNT=1000000
SEED=42
ZIPF_EXP=1.0

mkdir -p "$OUTPUT_DIR"

for shards in "${SHARDS[@]}"; do
  for skew in "${SKEWS[@]}"; do
    for prices in "${PRICES[@]}"; do
      output_file="$OUTPUT_DIR/multi_${shards}_${skew}_${prices}.txt"
      echo "Generating $output_file with seed=$SEED"
      python3 "$GENERATOR" "$skew" \
        --shards "$shards" \
        --count "$COUNT" \
        --seed "$SEED" \
        --zipf-exp "$ZIPF_EXP" \
        --prices "$prices" \
        --output "$output_file"
    done
  done
done
