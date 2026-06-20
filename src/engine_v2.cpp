#include "benchmark.hpp"
#include "types.hpp"
#include "parser.hpp"

#include <cstdlib>
#include <iostream>
#include <queue>
#include <string>
#include <vector>

std::priority_queue<Order, std::vector<Order>, BidComparator> bids;
std::priority_queue<Order, std::vector<Order>, AskComparator> asks;

std::vector<Transaction> transactions;

void insertOrder(const Order &order)
{
    if (order.order_side == OrderSide::Buy)
        bids.push(order);
    else
        asks.push(order);
}

void matchOrders()
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

int main(int argc, char **argv)
{
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(nullptr);

    bool benchmark_mode = false;
    for (int i = 1; i < argc; i++)
    {
        if (std::string(argv[i]) == "--benchmark")
            benchmark_mode = true;
    }

    std::vector<Order> orders = parseOrders();
    BenchmarkRunner benchmark(benchmark_mode);
    benchmark.reserve(orders.size());

    benchmark.startBatch();

    for (const auto &order : orders)
    {
        const auto order_start = benchmark.startOperation();

        insertOrder(order);
        matchOrders();

        benchmark.endOperation(order_start);
    }

    if (benchmark_mode)
    {
        const BenchmarkStats stats = benchmark.finishBatch();
        benchmark.printStats(stats, transactions.size());
        return EXIT_SUCCESS;
    }

    std::cout << transactions.size() << std::endl;
    for (const auto &transaction : transactions)
    {
        std::cout << transaction.count << " " << transaction.buy_order_id << " " << transaction.sell_order_id << std::endl;
    }
}
