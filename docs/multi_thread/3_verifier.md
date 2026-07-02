# Verifier

Verifying a multithreaded engine requires a different approach from verifying a single-threaded engine. Because thread interleavings may differ between runs, each run may produce a different output while still being correct.

Therefore, verification is performed in two layers. The first layer verifies that all orders are received and that each thread processes its assigned orders in the correct sequence. The second layer replays the recorded engine activity using the single-threaded engine v3 as a reference implementation.

## Order Reception Sequentiality Check

In the multithreaded configuration, the orders from the test case are distributed across `N` threads using the following function:

```c++
std::vector<std::vector<Order>> splitOrders(std::vector<Order> &orders, int N)
{
    std::vector<std::vector<Order>> res(N);
    for (int i = 0; i < orders.size(); i++)
    {
        res[i % N].push_back(orders[i]);
    }
    return res;
}
```

The verifier checks two properties:

1. Every input order is processed exactly once.
2. Within each thread, orders are processed in the same order as they appear in that thread's assigned order list.

Three data structures are used to implement this check.

The first is `std::set<int> current_order_ids`, which stores the order ID currently expected from each thread. The second is `std::vector<int> ptrs`, which stores the position of each thread within its assigned order list. The third is `std::map<int, int> order_id_to_thread_map`, which maps each currently expected order ID to the thread responsible for processing it.

The verifier iterates through the complete order-reception history. For each received order, it checks whether the order ID exists in `current_order_ids`. If it does not, the order was either processed out of sequence, processed more than once, or was not part of the input.

Otherwise, the verifier uses `order_id_to_thread_map` to identify the corresponding thread. It then advances that thread's pointer in `ptrs`, removes the processed order ID from both `current_order_ids` and `order_id_to_thread_map`, and inserts the next expected order ID for that thread, if one exists.

After the complete history has been processed, the verifier checks that every thread's pointer has reached the end of its assigned order list. This confirms that all input orders were processed exactly once and in the correct per-thread sequence.

## Replay Check

To support replay verification, `EngineV5` maintains a vector of `Log` objects containing the chronological history of its order-reception and transaction events. The `Log` structure is defined as follows:

```c++
struct Log
{
    LogType log_type;
    // For Receive
    Order order;
    // For Match
    Transaction transaction;

    Log(LogType new_log_type, const Order &new_order)
        : log_type{new_log_type},
          order{new_order} {}

    Log(LogType new_log_type, const Transaction &new_transaction)
        : log_type{new_log_type},
          transaction{new_transaction} {}
};
```

The replay verifier processes these logs sequentially using an `EngineV3` instance as the reference engine.

Whenever an order-reception log is encountered, the recorded order is passed to `EngineV3::receive`. The transactions returned by the corresponding matching operation are stored in a pending transaction list.

Subsequent transaction logs are compared against this pending list in order. Each recorded transaction must match the next expected transaction produced by `EngineV3`.

Additional order-reception logs are permitted while the pending list is non-empty. However, processing such an order must not cause the reference engine to produce another non-empty transaction list before the existing pending transactions have been exhausted. This restriction ensures that the transaction grouping and ordering observed in `EngineV5` remain consistent with a valid sequential execution.

At the end of the replay, the verifier checks that the pending transaction list is empty. If all pending transactions have been matched, the recorded execution is considered consistent with the reference engine. Otherwise, the multithreaded execution is rejected as inconsistent, and an error is reported.
