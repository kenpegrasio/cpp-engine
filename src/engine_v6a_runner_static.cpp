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

extern std::mutex merge_mtx, push_merge_mtx;

bool benchmark_mode = false;

int main(int argc, char **argv)
{
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(nullptr);

    int shard_count = MAX_SHARDS; // default number of shards, can be overridden by command line argument
    updateMode(argc, argv, benchmark_mode);
    updateShards(argc, argv, shard_count);

    printWorkerWarning(shard_count);

    auto orders = parseMultishardOrders();

    EngineV6A engine;

    BenchmarkRunner agg_queue(benchmark_mode), agg_match(benchmark_mode), agg_total(benchmark_mode), agg_push(benchmark_mode);
    std::barrier sync_start(shard_count, [&]() noexcept
                            { agg_queue.startBatch(); agg_match.startBatch(); agg_total.startBatch(); agg_push.startBatch(); });
    std::barrier sync_end_shard(shard_count, [&]() noexcept
                                { agg_queue.stopBatch(); agg_match.stopBatch(); agg_total.stopBatch(); agg_push.stopBatch(); });
    agg_queue.reserve(orders.size());
    agg_match.reserve(orders.size());
    agg_total.reserve(orders.size());
    agg_push.reserve(orders.size());

    for (int i = 0; i < shard_count; i++)
        engine.engines[i].transactions.reserve(orders.size() * 2);

    CoreAllocator core_allocator;

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

    for (const auto &order : orders)
    {
        BenchmarkRunner benchmark_push(benchmark_mode);
        benchmark_push.reserve(orders.size());
        engine.route(order, benchmark_push);
        agg_push.merge(benchmark_push);
    }
    for (int i = 0; i < MAX_SHARDS; i++)
        engine.is_finish[i].store(true);
    engine.close_shard_queues();

    std::vector<std::thread> workers;
    for (int i = 0; i < shard_count; i++)
        workers.emplace_back(shard_worker, i);

    for (auto &thread : workers)
        thread.join();

    printResults<EngineV6A>(engine, shard_count, benchmark_mode, agg_queue, agg_match, agg_total, agg_push);
}