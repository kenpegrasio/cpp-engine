#include "benchmark.hpp"
#include "types.hpp"
#include "Parser.hpp"

#include <cstdlib>
#include <iostream>
#include <queue>
#include <string>
#include <vector>

std::priority_queue<Order *, std::vector<Order *>, BidPointerComparator> bids;
std::priority_queue<Order *, std::vector<Order *>, AskPointerComparator> asks;

std::vector<Transaction> transactions;

void matchOrders()
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

    std::vector<Order *> orders = parseOrdersToPointers();
    BenchmarkRunner benchmark(benchmark_mode);
    benchmark.reserve(orders.size());

    benchmark.startBatch();

    for (const auto &order : orders)
    {
        const auto order_start = benchmark.startOperation();

        if (order->order_side == OrderSide::Buy)
            bids.push(order);
        else
            asks.push(order);
        matchOrders();

        benchmark.endOperation(order_start);
    }

    if (benchmark_mode)
    {
        const BenchmarkStats stats = benchmark.finishBatch();
        benchmark.printStats(stats, transactions.size());
    }

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

    if (benchmark_mode)
    {
        return EXIT_SUCCESS;
    }

    std::cout << transactions.size() << std::endl;
    for (const auto &transaction : transactions)
    {
        std::cout << transaction.count << " " << transaction.buy_order_id << " " << transaction.sell_order_id << std::endl;
    }
}
