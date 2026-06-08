# Latency Distribution Analysis

When the three single-threaded engines are benchmarked on the wide-range mixed workload, we observe an interesting latency distribution pattern.

![Figure 2: Latency and throughput comparison across the three single-threaded matching engine designs on the wide-range mixed workload.](../assets/bench_wide_range_mixed.png)

At first glance, v3 appears to have a worse median latency than v1: its p50 latency is higher. However, the trend reverses in the tail. v3 achieves lower p95, p99, and p99.9 latency than v1.

This result raises the main question for this section:

> Why is v3’s p50 latency worse than v1’s p50 latency, while v3 achieves better p95, p99, and p99.9 latency?
