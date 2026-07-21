#include "engines.hpp"

void EngineV6A::route(const Order &order, BenchmarkRunner &benchmark_push)
{
    const auto push_start = benchmark_push.startOperation();
    shard_queues[order.shard_id].push({order, std::chrono::steady_clock::now()});
    benchmark_push.endOperation(push_start);
}

void EngineV6A::process(int shard_id, BenchmarkRunner &benchmark_queue, BenchmarkRunner &benchmark_match, BenchmarkRunner &benchmark_total)
{
    auto &engine = engines[shard_id];
    while (!is_finish[shard_id].load() || !shard_queues[shard_id].empty())
    {
        std::optional<TimedOrder> timed_order = shard_queues[shard_id].pop();
        if (!timed_order.has_value())
            continue;
        auto &order = timed_order.value().order;
        auto t_enqueue = timed_order.value().t_enqueue;
        auto t_dequeue = std::chrono::steady_clock::now();
        benchmark_queue.pushLatency(std::chrono::duration_cast<std::chrono::nanoseconds>(t_dequeue - t_enqueue).count());
        engine.receive(order);
        engine.match();
        auto t_end = std::chrono::steady_clock::now();
        benchmark_match.pushLatency(std::chrono::duration_cast<std::chrono::nanoseconds>(t_end - t_dequeue).count());
        benchmark_total.pushLatency(std::chrono::duration_cast<std::chrono::nanoseconds>(t_end - t_enqueue).count());
    }
}