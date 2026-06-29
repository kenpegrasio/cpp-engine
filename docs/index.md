Welcome! 

This page chronicles my journey toward understanding how to build and optimize a high-frequency matching engine. 

Along the way, I will discuss the design choices, benchmarking methodology, and trade-offs between p50-p99.9 latency and throughput, backed by experimental results and analysis. 

The project is divided into several phases, with each phase building on the designs, findings, and limitations uncovered in the previous one:

1. **Phase 1**: [Single-Shard Single-Threaded Matching Engine](./single_thread/1_benchmark_controls.md)
2. **Phase 2**: [Single-Shard Multithreaded Matching Engine](./multi_thread/1_benchmark.md)