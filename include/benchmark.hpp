#ifndef BENCHMARK_HPP
#define BENCHMARK_HPP

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

struct BenchmarkStats
{
    double elapsed_ms;
    double operations_per_sec;
    double avg_latency_ns;
    std::uint64_t p50_latency_ns;
    std::uint64_t p95_latency_ns;
    std::uint64_t p99_latency_ns;
    std::uint64_t p999_latency_ns;
    std::uint64_t max_latency_ns;
};

class BenchmarkRunner
{
public:
    using Clock = std::chrono::steady_clock;

    explicit BenchmarkRunner(bool enabled = false)
        : enabled_(enabled) {}

    void reserve(std::size_t sample_count)
    {
        if (enabled_)
            latencies_ns_.reserve(sample_count);
    }

    void startBatch()
    {
        if (enabled_)
            batch_start_ = Clock::now();
    }

    Clock::time_point startOperation() const
    {
        return enabled_ ? Clock::now() : Clock::time_point{};
    }

    void endOperation(const Clock::time_point &operation_start)
    {
        if (!enabled_)
            return;

        const auto operation_end = Clock::now();
        latencies_ns_.push_back(static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(operation_end - operation_start).count()));
    }

    BenchmarkStats finishBatch()
    {
        if (enabled_)
            batch_end_ = Clock::now();

        return computeStats();
    }

    void printStats(const BenchmarkStats &stats,
                    std::size_t event_count,
                    const std::string &event_label = "transactions") const
    {
        std::cerr << std::fixed << std::setprecision(3);
        std::cerr << "elapsed_ms=" << stats.elapsed_ms << '\n';
        std::cerr << "operations_per_sec=" << stats.operations_per_sec << '\n';
        std::cerr << "avg_latency_ns=" << stats.avg_latency_ns << '\n';
        std::cerr << "p50_latency_ns=" << stats.p50_latency_ns << '\n';
        std::cerr << "p95_latency_ns=" << stats.p95_latency_ns << '\n';
        std::cerr << "p99_latency_ns=" << stats.p99_latency_ns << '\n';
        std::cerr << "p99_9_latency_ns=" << stats.p999_latency_ns << '\n';
        std::cerr << "max_latency_ns=" << stats.max_latency_ns << '\n';
        std::cerr << event_label << '=' << event_count << '\n';
    }

private:
    static std::uint64_t percentileLatency(std::vector<std::uint64_t> values, double percentile)
    {
        if (values.empty())
            return 0;

        const std::size_t index = static_cast<std::size_t>(
            std::clamp(percentile, 0.0, 1.0) * static_cast<double>(values.size() - 1));

        std::nth_element(values.begin(), values.begin() + index, values.end());
        return values[index];
    }

    BenchmarkStats computeStats() const
    {
        const double elapsed_ns = static_cast<double>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(batch_end_ - batch_start_).count());
        const double elapsed_ms = elapsed_ns / 1e6;
        const double elapsed_sec = elapsed_ns / 1e9;

        std::uint64_t max_latency_ns = 0;
        double total_latency_ns = 0.0;

        for (std::uint64_t latency_ns : latencies_ns_)
        {
            total_latency_ns += static_cast<double>(latency_ns);
            max_latency_ns = std::max(max_latency_ns, latency_ns);
        }

        BenchmarkStats stats{};
        stats.elapsed_ms = elapsed_ms;
        stats.operations_per_sec = elapsed_sec > 0.0
                                       ? static_cast<double>(latencies_ns_.size()) / elapsed_sec
                                       : 0.0;
        stats.avg_latency_ns = latencies_ns_.empty()
                                   ? 0.0
                                   : total_latency_ns / static_cast<double>(latencies_ns_.size());
        stats.p50_latency_ns = percentileLatency(latencies_ns_, 0.50);
        stats.p95_latency_ns = percentileLatency(latencies_ns_, 0.95);
        stats.p99_latency_ns = percentileLatency(latencies_ns_, 0.99);
        stats.p999_latency_ns = percentileLatency(latencies_ns_, 0.999);
        stats.max_latency_ns = max_latency_ns;
        return stats;
    }

    bool enabled_;
    Clock::time_point batch_start_{};
    Clock::time_point batch_end_{};
    std::vector<std::uint64_t> latencies_ns_;
};

#endif
