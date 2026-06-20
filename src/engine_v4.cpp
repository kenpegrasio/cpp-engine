#include "engines.hpp"

#include <thread>

void EngineV4::receive(const Order &order)
{
    logs.push_back(Log(LogType::Receive, order));
    if (order.order_side == OrderSide::Buy)
        bids[order.price].push_back(order);
    else
        asks[order.price].push_back(order);
}

void EngineV4::match()
{
    auto highest_bid_entry = bids.rbegin();
    auto lowest_ask_entry = asks.begin();
    while (highest_bid_entry != bids.rend() && lowest_ask_entry != asks.end())
    {
        auto &highest_bid_deque = highest_bid_entry->second;
        auto &lowest_ask_deque = lowest_ask_entry->second;

        auto &highest_bid = highest_bid_deque.front();
        auto &lowest_ask = lowest_ask_deque.front();

        if (highest_bid.price < lowest_ask.price)
            break;

        if (highest_bid.count > lowest_ask.count)
        {
            highest_bid.count -= lowest_ask.count;
            logs.push_back(Log(LogType::Match,
                               Transaction(
                                   highest_bid.order_id,
                                   lowest_ask.order_id,
                                   lowest_ask.count)));
            lowest_ask_deque.pop_front();
            if (lowest_ask_deque.empty())
            {
                asks.erase(lowest_ask_entry);
                lowest_ask_entry = asks.begin();
            }
        }
        else if (highest_bid.count < lowest_ask.count)
        {
            lowest_ask.count -= highest_bid.count;
            logs.push_back(Log(LogType::Match,
                               Transaction(
                                   highest_bid.order_id,
                                   lowest_ask.order_id,
                                   highest_bid.count)));
            highest_bid_deque.pop_front();
            if (highest_bid_deque.empty())
            {
                bids.erase(std::next(highest_bid_entry).base());
                highest_bid_entry = bids.rbegin();
            }
        }
        else
        {
            logs.push_back(Log(LogType::Match,
                               Transaction(
                                   highest_bid.order_id,
                                   lowest_ask.order_id,
                                   highest_bid.count)));
            highest_bid_deque.pop_front();
            lowest_ask_deque.pop_front();
            if (highest_bid_deque.empty())
            {
                bids.erase(std::next(highest_bid_entry).base());
                highest_bid_entry = bids.rbegin();
            }
            if (lowest_ask_deque.empty())
            {
                asks.erase(lowest_ask_entry);
                lowest_ask_entry = asks.begin();
            }
        }
    }
}

void EngineV4::process(const Order &order)
{
    std::lock_guard<std::mutex> lock(mtx);
    receive(order);
    match();
}