#include "benchmark.hpp"
#include "types.hpp"
#include "parser.hpp"
#include "engines.hpp"

#include <cstdlib>
#include <iostream>
#include <queue>
#include <string>
#include <vector>

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

    EngineV2 engine;

    benchmark.startBatch();

    for (const auto &order : orders)
    {
        const auto order_start = benchmark.startOperation();

        engine.receive(order);
        engine.match();

        benchmark.endOperation(order_start);
    }

    if (benchmark_mode)
    {
        const BenchmarkStats stats = benchmark.finishBatch();
        benchmark.printStats(stats, engine.transactions.size());
        return EXIT_SUCCESS;
    }

    std::cout << engine.transactions.size() << std::endl;
    for (const auto &transaction : engine.transactions)
    {
        std::cout << transaction.count << " " << transaction.buy_order_id << " " << transaction.sell_order_id << std::endl;
    }
}
