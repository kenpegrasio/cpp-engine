#include "engines.hpp"

void EngineV3::receive(const Order &order)
{
    if (order.order_side == OrderSide::Buy)
        bids[order.price].push_back(order);
    else
        asks[order.price].push_back(order);
}

std::span<const Transaction> EngineV3::match()
{
    const auto begin = transactions.size();
    auto highest_bid_entry = bids.rbegin();
    auto lowest_ask_entry = asks.begin();
    while (highest_bid_entry != bids.rend() && lowest_ask_entry != asks.end())
    {
        // it is assumed here that index in the map will be removed when the deque is empty,
        // so when this condition is satisfied, the deque attached to the bids and asks will
        // always not empty
        auto &highest_bid_deque = highest_bid_entry->second;
        auto &lowest_ask_deque = lowest_ask_entry->second;

        auto &highest_bid = highest_bid_deque.front();
        auto &lowest_ask = lowest_ask_deque.front();

        if (highest_bid.price < lowest_ask.price)
            break;

        if (highest_bid.count > lowest_ask.count)
        {
            highest_bid.count -= lowest_ask.count;
            transactions.push_back(Transaction(
                highest_bid.order_id,
                lowest_ask.order_id,
                lowest_ask.count));
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
            transactions.push_back(Transaction(
                highest_bid.order_id,
                lowest_ask.order_id,
                highest_bid.count));
            highest_bid_deque.pop_front();
            if (highest_bid_deque.empty())
            {
                bids.erase(std::next(highest_bid_entry).base());
                highest_bid_entry = bids.rbegin();
            }
        }
        else
        {
            transactions.push_back(Transaction(
                highest_bid.order_id,
                lowest_ask.order_id,
                highest_bid.count));
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
    return std::span<const Transaction>(transactions.data() + begin, transactions.size() - begin);
}