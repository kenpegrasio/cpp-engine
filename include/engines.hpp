#ifndef ENGINES_HPP
#define ENGINES_HPP

#include "types.hpp"
#include <deque>
#include <map>
#include <span>
#include <vector>

class Engine
{
public:
    virtual void receive(const Order &order) = 0;
    virtual std::span<const Transaction> match() = 0;
};

class EngineV3 : public Engine
{
private:
    std::map<unsigned long long, std::deque<Order>> bids;
    std::map<unsigned long long, std::deque<Order>> asks;

public:
    std::vector<Transaction> transactions;
    void receive(const Order &order) override;
    std::span<const Transaction> match() override;
};

#endif