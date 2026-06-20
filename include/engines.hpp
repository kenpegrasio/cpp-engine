#ifndef ENGINES_HPP
#define ENGINES_HPP

#include "types.hpp"
#include <deque>
#include <map>
#include <span>
#include <vector>
#include <queue>

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

#endif