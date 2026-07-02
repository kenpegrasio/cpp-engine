# Fine-Grained Design

This section will discuss the design consideration behind engine v5. The class details for the engine can be found in the [Engines](./2_engines.md#engine-v5-fine-grained-locking) section. 

## Data Structures Backbone

> If the data structures backbone is based on engine v3, fine-grained implementation will suffer from race condition inside the map internal representation. 

The reason is the `operator[]` from `std::map` may perform insertion if the key is not found. During insertion, the internal red-black tree representation might experience some modifications due to rotations or change in internal values. This claim is supported by the following quotation from cppreference:

> [[cppreference](https://en.cppreference.com/cpp/container#Thread_safety)] All const member functions can be called concurrently by different threads on the same container. In addition, the member functions `begin()`, `end()`, `rbegin()`, `rend()`, `front()`, `back()`, `data()`, `find()`, `lower_bound()`, `upper_bound()`, `equal_range()`, `at()`, and, except in associative containers, `operator[]`. 

Given this concern, to extend the concurrency level to fine-grained, the data structures backbone need to be shifted from map to array. For all generated testcases, the price is in the range of 1 to 200 inclusively. With this, the `bids` and `asks` array should be sized accordingly. 

```c++
std::array<std::deque<Order>, MAX_PRICE + 1> bids;
std::array<std::deque<Order>, MAX_PRICE + 1> asks;
```

A constant variable `MAX_PRICE` will be maintained in case of future price changes. 

## Pitfall

> During matching, no orders should be inserted in `asks` and `bids`. Otherwise, if matching persists, we won't be able to identify the correct match because the arrival order is already distrupted. 

To illustrate, consider the case where `asks` contain one sell query where the price is 50 and count is 100 and `bids` contain one buy query where the price is 50 and count is 10. When matching occurs, suppose these two buy queries arrive with the following order:

1. Price is 60 and count is 20
2. Price is 70 and count is 10

After matching is finished, we should pick the one with price equals to 60 even though it has lower price because the query arrives first. However, this information has been lost; the procedure will treat all orders arrive at the same time and pick the one with highest bid price. 

With concern to this pitfall, we introduce a synchronization mechanism using a global atomic boolean called `is_matching` and a global matching lock called `matching_mutex`. If matching can happen, acquire the global lock and then update the global boolean. Otherwise, additional synchronization mechanism is required; it will be discussed in [Data Structures Requirement](./4_fine_grained.md#data-structures-requirement). 

The implementation of the synchronization mechanism when matching occurs is as follows:

```c++
void EngineV5::match()
{
    if (top_bids < lowest_asks)
        return;
    is_matching.store(true, std::memory_order_seq_cst);
    // Matching logic
    ...
    is_matching.store(false, std::memory_order_seq_cst);
    return;
}
```

> Note: `matching_mutex` is acquired before invoking the `match` function; more on this will be shown in the next section

## Data Structures Requirement

While array-based `asks` and `bids` can support higher level of concurrency through fine-grained locking, top bids and lowest asks price need to be maintained manually; name the variables `top_bids` and `lowest_asks` accordingly. As many threads operate on these variables, synchronization is required. 

The scenario where matching occurs has been covered in the [Pitfall](./4_fine_grained.md#pitfall) section. We will focus on the scenario where matching does not happen. There are two cases: 

1. No update to `top_bids` and `lowest_asks` is required
2. Update is required

For case 1, the synchronization we need is only a read lock to the corresponding variables during the check. For case 2, because changing variables value might cause matching to occur, we will acquire the global matching lock and write lock both `top_bids` and `lowest_asks`. We cannot write lock only one of them because both variables might potentially change values during matching. 

> **Why we cannot acquire matching lock and write lock to the other pair only when matching is detected?** Suppose we are updating `top_bids` and we only write lock `top_bids`. Consider the case where we are expecting that matching occurs. During the period between write locking and acquiring global matching lock & other write lock pair, another thread might slip in. This thread might update `lowest_asks` and by the same logic only write lock `lowest_asks`. Going back to the initial thread, now deadlock has occured. The initial thread who holds the `top_bids` are waiting for `lowest_asks` while the other thread who holds the `lowest_asks` are waiting for `top_bids`. 

For the 1st case, the implementation for the sell side is shown below; for the buy side, the implementation is the mirror version of it. 

```c++
case OrderSide::Sell:
{
    if (!is_matching.load(std::memory_order_seq_cst))
    {
        std::shared_lock<std::shared_mutex> read_lock{lowest_asks_mutex};
        if (lowest_asks <= order.price)
        {
            std::lock_guard<std::mutex> fine_grained_lock{asks_mutex[order.price]};
            {
                std::lock_guard<std::mutex> logs_lock{logs_mutex};
                logs.push_back(Log(LogType::Receive, order));
            }
            asks[order.price].push_back(order);
            break;
        }
    }
    ...
}
```

The implementation for the 2nd case is the same as the one used when matching occurs; the code is as follows:

```c++
case OrderSide::Sell:
{
    if (!is_matching.load(std::memory_order_seq_cst)) { ... }
    std::scoped_lock lock{top_bids_mutex, lowest_asks_mutex, matching_mutex};
    {
        std::lock_guard<std::mutex> fine_grained_lock{asks_mutex[order.price]};
        {
            std::lock_guard<std::mutex> logs_lock{logs_mutex};
            logs.push_back(Log(LogType::Receive, order));
        }
        asks[order.price].push_back(order);
    }
    if (lowest_asks <= order.price)
        break;
    lowest_asks = order.price;
    match();
    break;
}
```
