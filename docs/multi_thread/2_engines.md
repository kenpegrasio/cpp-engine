# Engines

In this phase, two single-shard multithreaded matching engine designs will be analyzed. Each design uses different synchronization designs, which allows us to study how synchronization design choices affect throughput, median latency, tail latency, and microarchitectural behavior.

The two implementations are engine v4 (Coarse-grained locking) and v5 (Fine-grained locking). As engine v5 uses different base data structure as engine v3. A single thread implementation of engine v5 is provided to isolate performance effects from the data structures change, call it engine v5S. 

## Engine v4: Coarse-grained locking

```cpp
class EngineV4
{
private:
    std::map<unsigned long long, std::deque<Order>> bids;
    std::map<unsigned long long, std::deque<Order>> asks;
    std::mutex mtx;

public:
    std::vector<Log> logs;
    void receive(const Order &order);
    void match();
    void process(const Order &order);
};
```

## Engine v5: Fine-grained locking

```cpp
class EngineV5
{
private:
    std::array<std::deque<Order>, MAX_PRICE + 1> bids;
    std::array<std::deque<Order>, MAX_PRICE + 1> asks;
    std::array<std::mutex, MAX_PRICE + 1> bids_mutex;
    std::array<std::mutex, MAX_PRICE + 1> asks_mutex;
    std::mutex matching_mutex, logs_mutex;
    std::shared_mutex top_bids_mutex, lowest_asks_mutex;
    int top_bids{0}, lowest_asks{MAX_PRICE + 1};
    std::atomic<int> interior_insert{0};
    std::atomic<bool> is_matching{false};
    void match();

public:
    std::vector<Log> logs;
    void process(const Order &order);
};
```

## Engine v5S

```c++
class EngineV5S
{
private:
    std::array<std::deque<Order>, MAX_PRICE + 1> bids;
    std::array<std::deque<Order>, MAX_PRICE + 1> asks;
    int top_bids{0}, lowest_asks{MAX_PRICE + 1};

public:
    std::vector<Transaction> transactions;
    void receive(const Order &order);
    void match();
};
```