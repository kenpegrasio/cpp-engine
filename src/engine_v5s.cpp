#include "engines.hpp"

#include <algorithm>

void EngineV5S::receive(const Order &order)
{
    if (order.order_side == OrderSide::Buy)
    {
        bids[order.price].push_back(order);
        top_bids = std::max(1ull * top_bids, order.price);
    }
    else
    {
        asks[order.price].push_back(order);
        lowest_asks = std::min(1ull * lowest_asks, order.price);
    }
}

void EngineV5S::match()
{
    if (top_bids < lowest_asks)
        return;
    while (top_bids >= lowest_asks)
    {
        auto &highest_bid_order = bids[top_bids].front();
        auto &lowest_ask_order = asks[lowest_asks].front();

        if (highest_bid_order.count > lowest_ask_order.count)
        {
            highest_bid_order.count -= lowest_ask_order.count;
            transactions.push_back(Transaction(
                highest_bid_order.order_id,
                lowest_ask_order.order_id,
                lowest_ask_order.count));
            asks[lowest_asks].pop_front();
            while (lowest_asks <= MAX_PRICE && asks[lowest_asks].empty())
                lowest_asks++;
        }
        else if (highest_bid_order.count < lowest_ask_order.count)
        {
            lowest_ask_order.count -= highest_bid_order.count;
            transactions.push_back(Transaction(
                highest_bid_order.order_id,
                lowest_ask_order.order_id,
                highest_bid_order.count));
            bids[top_bids].pop_front();
            while (top_bids >= 1 && bids[top_bids].empty())
                top_bids--;
        }
        else
        {
            transactions.push_back(Transaction(
                highest_bid_order.order_id,
                lowest_ask_order.order_id,
                highest_bid_order.count));
            asks[lowest_asks].pop_front();
            while (lowest_asks <= MAX_PRICE && asks[lowest_asks].empty())
                lowest_asks++;
            bids[top_bids].pop_front();
            while (top_bids >= 1 && bids[top_bids].empty())
                top_bids--;
        }
    }
}