# Engines

This write-up analyzes three single-threaded matching engine designs. Each design uses a different internal representation for the bid and ask books, which allows us to study how data structure choices affect throughput, median latency, tail latency, and microarchitectural behavior.

The three implementations are:

| Engine | Design                           | Internal Representation                           |
| ------ | -------------------------------- | ------------------------------------------------- |
| v1     | Pointer-based priority queue     | `std::priority_queue<Order*>`                     |
| v2     | Value-based priority queue       | `std::priority_queue<Order>`                      |
| v3     | Price-level map with FIFO queues | `std::map<unsigned long long, std::deque<Order>>` |
