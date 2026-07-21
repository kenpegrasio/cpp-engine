#ifndef MULTISHARD_UTILS_HPP
#define MULTISHARD_UTILS_HPP

#include "types.hpp"
#include "benchmark.hpp"
#include "constants.hpp"

#include <vector>
#include <barrier>

std::mutex merge_mtx, push_merge_mtx;

void printWorkerWarning(int worker_count)
{
    if (worker_count > NUMBER_OF_PHYSICAL_P_CORES && worker_count <= 2 * NUMBER_OF_PHYSICAL_P_CORES)
    {
        std::cerr << "Warning: worker is greater than the number of physical P-cores. Threads is placed on hyperthread siblings and may share the same resources, like L1/L2 cache" << std::endl;
    }
    if (worker_count > 2 * NUMBER_OF_PHYSICAL_P_CORES)
    {
        std::cerr << "Warning: worker is greater than or equal to the number of logical CPUs. Performance may be degraded due to time-slicing." << std::endl;
    }
}

void updateN(int argc, char **argv, int &N)
{
    for (int i = 1; i < argc; i++)
    {
        if (std::string(argv[i]) == "--N")
        {
            if (i + 1 < argc)
            {
                N = std::stoi(argv[i + 1]);
                i++;
            }
            else
            {
                std::cerr << "Error: --N option requires an argument." << std::endl;
                std::exit(EXIT_FAILURE);
            }
        }
    }
}

void updateMode(int argc, char **argv, bool &benchmark_mode)
{
    for (int i = 1; i < argc; i++)
    {
        if (std::string(argv[i]) == "--benchmark")
            benchmark_mode = true;
    }
}

void updateShards(int argc, char **argv, int &shard_count)
{
    for (int i = 1; i < argc; i++)
    {
        if (std::string(argv[i]) == "--shard")
        {
            if (i + 1 < argc)
            {
                shard_count = std::stoi(argv[i + 1]);
                i++;
            }
            else
            {
                std::cerr << "Error: --shard option requires an argument." << std::endl;
                std::exit(EXIT_FAILURE);
            }
        }
    }
}

template <typename MultishardEngine>
void printResults(MultishardEngine &engine, int shard_count, bool benchmark_mode,
                  BenchmarkRunner &agg_queue, BenchmarkRunner &agg_match,
                  BenchmarkRunner &agg_total, BenchmarkRunner &agg_push)
{
    int transactions_size = 0;
    for (int i = 0; i < shard_count; i++)
        transactions_size += engine.engines[i].transactions.size();

    if (benchmark_mode)
    {
        // The dump tags keep the three runners from truncating each other's
        // BENCH_PERF_DUMP file: <dump>.queue.csv / .match.csv / .total.csv.
        std::cerr << "Push stats:\n";
        const BenchmarkStats stats_push = agg_push.stats();
        agg_push.printStats(stats_push, transactions_size, "transactions", "push");

        std::cerr << "Queue stats:\n";
        const BenchmarkStats stats = agg_queue.stats();
        agg_queue.printStats(stats, transactions_size, "transactions", "queue");

        std::cerr << "Match stats:\n";
        const BenchmarkStats stats2 = agg_match.stats();
        agg_match.printStats(stats2, transactions_size, "transactions", "match");

        std::cerr << "Total stats:\n";
        const BenchmarkStats stats3 = agg_total.stats();
        agg_total.printStats(stats3, transactions_size, "transactions", "total");
    }

    std::cout << transactions_size << std::endl;
    for (const auto &engine : engine.engines)
    {
        for (const auto &transaction : engine.transactions)
            std::cout << transaction.count << " " << transaction.buy_order_id << " " << transaction.sell_order_id << std::endl;
    }
}

template <typename MultishardEngine>
void run(int N, int shard_count, int worker_count, bool benchmark_mode,
         std::vector<std::vector<Order>> &split_orders, std::vector<Order> &orders)
{
    MultishardEngine engine;

    BenchmarkRunner agg_queue(benchmark_mode), agg_match(benchmark_mode), agg_total(benchmark_mode), agg_push(benchmark_mode);
    std::barrier sync_start(worker_count, [&]() noexcept
                            { agg_queue.startBatch(); agg_match.startBatch(); agg_total.startBatch(); agg_push.startBatch(); });
    std::barrier sync_end_order(N, [&]() noexcept
                                {
        for (int i = 0; i < MAX_SHARDS; i++)
            engine.is_finish[i].store(true);
        engine.close_shard_queues(); });
    std::barrier sync_end_shard(shard_count, [&]() noexcept
                                { agg_queue.stopBatch(); agg_match.stopBatch(); agg_total.stopBatch(); agg_push.stopBatch(); });
    agg_queue.reserve(orders.size());
    agg_match.reserve(orders.size());
    agg_total.reserve(orders.size());
    agg_push.reserve(orders.size());

    for (int i = 0; i < shard_count; i++)
        engine.engines[i].transactions.reserve(orders.size() * 2);

    CoreAllocator core_allocator;

    auto order_worker = [&](int i)
    {
        pin_to_core(core_allocator.allocate());

        BenchmarkRunner benchmark_push(benchmark_mode);
        benchmark_push.reserve(split_orders[i].size());

        // Wait for all threads to start before processing orders to ensure a fair benchmark
        sync_start.arrive_and_wait();

        for (const auto &order : split_orders[i])
            engine.route(order, benchmark_push);

        // Wait for all threads to finish processing orders before finalizing the benchmark
        sync_end_order.arrive_and_wait();

        if (benchmark_mode)
        {
            std::lock_guard<std::mutex> lock(push_merge_mtx);
            agg_push.merge(benchmark_push);
        }
    };

    auto shard_worker = [&](int i)
    {
        pin_to_core(core_allocator.allocate());
        BenchmarkRunner benchmark_queue(benchmark_mode), benchmark_match(benchmark_mode), benchmark_total(benchmark_mode);
        benchmark_queue.reserve(orders.size());
        benchmark_match.reserve(orders.size());
        benchmark_total.reserve(orders.size());

        // Wait for all threads to start before processing orders to ensure a fair benchmark
        sync_start.arrive_and_wait();

        engine.process(i, benchmark_queue, benchmark_match, benchmark_total);

        // Wait for all threads to finish processing orders before finalizing the benchmark
        sync_end_shard.arrive_and_wait();

        if (benchmark_mode)
        {
            std::lock_guard<std::mutex> lock(merge_mtx);
            agg_queue.merge(benchmark_queue);
            agg_match.merge(benchmark_match);
            agg_total.merge(benchmark_total);
        }
    };

    std::vector<std::thread> workers;
    for (int i = 0; i < N; i++)
        workers.emplace_back(order_worker, i);
    for (int i = 0; i < shard_count; i++)
        workers.emplace_back(shard_worker, i);

    for (auto &thread : workers)
        thread.join();

    printResults<MultishardEngine>(engine, shard_count, benchmark_mode, agg_queue, agg_match, agg_total, agg_push);
}

#endif