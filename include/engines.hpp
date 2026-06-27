#ifndef ENGINES_HPP
#define ENGINES_HPP

#include "types.hpp"
#include "constants.hpp"

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

#endif