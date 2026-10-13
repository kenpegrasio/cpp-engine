#ifndef ENGINES_HPP
#define ENGINES_HPP

#include "types.hpp"
#include "constants.hpp"
#include "mutex_queue.hpp"
#include "nonblocking_mutex_queue.hpp"
#include "benchmark.hpp"

#include <deque>
#include <map>
#include <span>
#include <vector>
#include <queue>
#include <mutex>
#include <unordered_map>
#include <shared_mutex>
#include <atomic>
#include <span>
#include <array>

class EngineV1
{
private:
    std::priority_queue<Order *, std::vector<Order *>, BidPointerComparator> bids;
    std::priority_queue<Order *, std::vector<Order *>, AskPointerComparator> asks;

public:
    std::vector<Transaction> transactions;
    void receive(Order *order);
    void match();
    EngineV1() = default;
    EngineV1(const EngineV1 &other) = delete;
    EngineV1 &operator=(const EngineV1 &other) = delete;
    ~EngineV1();
};

class EngineV2
{
private:
    std::priority_queue<Order, std::vector<Order>, BidComparator> bids;
    std::priority_queue<Order, std::vector<Order>, AskComparator> asks;

public:
    std::vector<Transaction> transactions;
    void receive(const Order &order);
    void match();
};

class EngineV3
{
private:
    std::map<unsigned long long, std::deque<Order>> bids;
    std::map<unsigned long long, std::deque<Order>> asks;

public:
    std::vector<Transaction> transactions;
    void receive(const Order &order);
    std::span<const Transaction> match();
};

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

struct alignas(64) PaddedMutex
{
    std::mutex mtx;
};

struct alignas(64) PaddedSharedMutex
{
    std::shared_mutex mtx;
};

class EngineV5
{
private:
    std::array<std::deque<Order>, MAX_PRICE + 1> bids;
    std::array<std::deque<Order>, MAX_PRICE + 1> asks;
    std::array<PaddedMutex, MAX_PRICE + 1> bids_mutex;
    std::array<PaddedMutex, MAX_PRICE + 1> asks_mutex;
    PaddedMutex matching_mutex;
    PaddedSharedMutex top_bids_mutex, lowest_asks_mutex;
    int top_bids{0}, lowest_asks{MAX_PRICE + 1};
    std::atomic<bool> is_matching{false};
    void match(std::vector<Log> &logs);

public:
    void process(const Order &order, std::vector<Log> &logs);
};

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

class EngineV6A
{
private:
    std::array<MutexQueue<TimedOrder>, MAX_SHARDS> shard_queues;

public:
    std::array<EngineV5S, MAX_SHARDS> engines;
    std::array<std::atomic<bool>, MAX_SHARDS> is_finish;
    void route(const Order &order, BenchmarkRunner &benchmark_push);
    void process(int shard_id, BenchmarkRunner &benchmark_queue, BenchmarkRunner &benchmark_match, BenchmarkRunner &benchmark_total);
    void close_shard_queues()
    {
        for (int i = 0; i < MAX_SHARDS; i++)
            shard_queues[i].close();
    }

    EngineV6A()
    {
        for (int i = 0; i < MAX_SHARDS; i++)
            is_finish[i].store(false);
    }
};

class EngineV6A_NB
{
private:
    std::array<NonblockingMutexQueue<TimedOrder>, MAX_SHARDS> shard_queues;

public:
    std::array<EngineV5S, MAX_SHARDS> engines;
    std::array<std::atomic<bool>, MAX_SHARDS> is_finish;
    void route(const Order &order, BenchmarkRunner &benchmark_push);
    void process(int shard_id, BenchmarkRunner &benchmark_queue, BenchmarkRunner &benchmark_match, BenchmarkRunner &benchmark_total);
    void close_shard_queues() {};

    EngineV6A_NB()
    {
        for (int i = 0; i < MAX_SHARDS; i++)
            is_finish[i].store(false);
    }
};

class EngineV6B
{
private:
    std::array<PaddedMutex, MAX_SHARDS> shard_mutexes;

public:
    std::array<EngineV5S, MAX_SHARDS> engines;
    void process(const Order &order);
};

#endif