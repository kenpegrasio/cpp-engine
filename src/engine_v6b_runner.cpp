#include "benchmark.hpp"
#include "types.hpp"
#include "parser.hpp"
#include "utils.hpp"
#include "core_allocator.hpp"
#include "engines.hpp"
#include "multishard_utils.hpp"

#include <map>
#include <deque>
#include <thread>
#include <barrier>

extern std::mutex merge_mtx;

bool benchmark_mode = false;

int main(int argc, char **argv)
{
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(nullptr);

    int N = NUMBER_OF_PHYSICAL_P_CORES; // default number of threads, can be overridden by command line argument
    int shard_count = MAX_SHARDS;       // default number of shards, can be overridden by command line argument
    updateN(argc, argv, N);
    updateShards(argc, argv, shard_count);
    updateMode(argc, argv, benchmark_mode);

    printWorkerWarning(N);

    auto orders = parseMultishardOrders();
    std::vector<std::vector<Order>> split_orders = splitOrders(orders, N);

    EngineV6B engine;

    BenchmarkRunner agg(benchmark_mode);
    std::barrier sync_start(N, [&]() noexcept
                            { agg.startBatch(); });
    std::barrier sync_end(N, [&]() noexcept
                          { agg.stopBatch(); });
    agg.reserve(orders.size());

    for (int i = 0; i < shard_count; i++)
        engine.engines[i].transactions.reserve(orders.size() * 2);

    CoreAllocator core_allocator;

    auto order_worker = [&](int i)
    {
        pin_to_core(core_allocator.allocate());

        BenchmarkRunner bench(benchmark_mode);
        bench.reserve(split_orders[i].size());

        // Wait for all threads to start before processing orders to ensure a fair benchmark
        sync_start.arrive_and_wait();

        for (auto &order : split_orders[i])
        {
            auto order_start = bench.startOperation();
            engine.process(order);
            bench.endOperation(order_start);
        }

        // Wait for all threads to finish processing orders before finalizing the benchmark
        sync_end.arrive_and_wait();

        if (benchmark_mode)
        {
            std::lock_guard<std::mutex> lock(merge_mtx);
            agg.merge(bench);
        }
    };

    std::vector<std::thread> workers;
    for (int i = 0; i < N; i++)
        workers.emplace_back(order_worker, i);

    for (auto &thread : workers)
        thread.join();

    int transactions_size = 0;
    for (int i = 0; i < shard_count; i++)
        transactions_size += engine.engines[i].transactions.size();

    if (benchmark_mode)
    {
        std::cerr << "Total stats:\n";
        const BenchmarkStats stats = agg.stats();
        agg.printStats(stats, transactions_size, "transactions", "total");
        return EXIT_SUCCESS;
    }

    std::cout << transactions_size << std::endl;
    for (const auto &engine : engine.engines)
    {
        for (const auto &transaction : engine.transactions)
            std::cout << transaction.count << " " << transaction.buy_order_id << " " << transaction.sell_order_id << std::endl;
    }
}