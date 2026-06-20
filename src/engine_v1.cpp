#include "engines.hpp"

void EngineV1::receive(Order *order)
{
    if (order->order_side == OrderSide::Buy)
        bids.push(order);
    else
        asks.push(order);
}

void EngineV1::match()
{
    while (!bids.empty() && !asks.empty())
    {
        auto highestBuy = bids.top();
        auto lowestSell = asks.top();
        if (highestBuy->price < lowestSell->price)
            break;

        if (highestBuy->count > lowestSell->count)
        {
            highestBuy->count -= lowestSell->count;
            transactions.push_back(Transaction(
                highestBuy->order_id,
                lowestSell->order_id,
                lowestSell->count));
            asks.pop();
            delete lowestSell;
        }
        else if (highestBuy->count < lowestSell->count)
        {
            lowestSell->count -= highestBuy->count;
            transactions.push_back(Transaction(
                highestBuy->order_id,
                lowestSell->order_id,
                highestBuy->count));
            bids.pop();
            delete highestBuy;
        }
        else
        {
            transactions.push_back(Transaction(
                highestBuy->order_id,
                lowestSell->order_id,
                highestBuy->count));
            asks.pop();
            bids.pop();
            delete highestBuy;
            delete lowestSell;
        }
    }
}

EngineV1::~EngineV1()
{
    // Cleanup
    while (!bids.empty())
    {
        auto bid = bids.top();
        bids.pop();
        delete bid;
    }
    while (!asks.empty())
    {
        auto ask = asks.top();
        asks.pop();
        delete ask;
    }
}