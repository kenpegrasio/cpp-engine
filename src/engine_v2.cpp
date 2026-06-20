#include "engines.hpp"

void EngineV2::receive(const Order &order)
{
    if (order.order_side == OrderSide::Buy)
        bids.push(order);
    else
        asks.push(order);
}

void EngineV2::match()
{
    while (!bids.empty() && !asks.empty())
    {
        Order highestBuy = bids.top();
        Order lowestSell = asks.top();
        if (highestBuy.price < lowestSell.price)
            break;

        bids.pop();
        asks.pop();

        if (highestBuy.count > lowestSell.count)
        {
            bids.push(Order(highestBuy.order_id,
                            OrderSide::Buy,
                            highestBuy.count - lowestSell.count,
                            highestBuy.price));
            transactions.push_back(Transaction(
                highestBuy.order_id,
                lowestSell.order_id,
                lowestSell.count));
        }
        else if (highestBuy.count < lowestSell.count)
        {
            asks.push(Order(lowestSell.order_id,
                            OrderSide::Sell,
                            lowestSell.count - highestBuy.count,
                            lowestSell.price));
            transactions.push_back(Transaction(
                highestBuy.order_id,
                lowestSell.order_id,
                highestBuy.count));
        }
        else
        {
            transactions.push_back(Transaction(
                highestBuy.order_id,
                lowestSell.order_id,
                highestBuy.count));
        }
    }
}