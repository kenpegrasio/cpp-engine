#ifndef BENCHMARK_HPP
#define BENCHMARK_HPP

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

#include "perf_counters.hpp"

struct BenchmarkStats
{
    double elapsed_ms;
    double operations_per_sec;
    double avg_latency_ns;
    std::uint64_t min_latency_ns;
    std::uint64_t p50_latency_ns;
    std::uint64_t p95_latency_ns;
    std::uint64_t p99_latency_ns;
    std::uint64_t p999_latency_ns;
    std::uint64_t max_latency_ns;
};

struct OpStart
{
    std::chrono::steady_clock::time_point t;
    std::array<std::uint64_t, PerfCounters::MAX_EVENTS> counters;
};

class BenchmarkRunner
{
public:
    using Clock = std::chrono::steady_clock;

    explicit BenchmarkRunner(bool enabled = false)
        : enabled_(enabled)
    {
        if (!enabled_)
            return;

        // ── Per-order events (BENCH_PERF_EVENTS, optional) ────────────────────
        if (const char *events_env = std::getenv("BENCH_PERF_EVENTS");
            events_env && *events_env)
        {
            std::vector<PerfCounters::EventSpec> specs;
            std::string s(events_env);
            std::size_t pos = 0;
            while (pos <= s.size())
            {
                const std::size_t end = std::min(s.find(',', pos), s.size());
                const std::string name = s.substr(pos, end - pos);
                if (name == "cache-misses")
                    specs.push_back(PerfCounters::event_cache_misses());
                else if (name == "LLC-load-misses")
                    specs.push_back(PerfCounters::event_llc_load_misses());
                else if (name == "dTLB-load-misses")
                    specs.push_back(PerfCounters::event_dtlb_load_misses());
                else if (name == "instructions")
                    specs.push_back(PerfCounters::event_instructions());
                else if (name == "cpu-cycles")
                    specs.push_back(PerfCounters::event_cpu_cycles());
                else if (!name.empty())
                    std::cerr << "[warn] BENCH_PERF_EVENTS: unknown event '" << name << "'\n";
                pos = end + 1;
            }
            if (!specs.empty())
            {
                perf_.open(specs);
                counter_samples_.resize(perf_.event_count());
            }
        }
    }

    void reserve(std::size_t sample_count)
    {
        if (!enabled_)
            return;
        latencies_ns_.reserve(sample_count);
        for (auto &v : counter_samples_)
            v.reserve(sample_count);
    }

    void startBatch()
    {
        if (!enabled_)
            return;
        batch_start_ = Clock::now();
    }

    // Stamp the end of the measured span without computing stats. Mirror of
    // startBatch(). Use this when the span boundary is owned by an external
    // rendezvous (e.g. a barrier completion fires stopBatch() the instant all
    // workers finish matching), so the wall-clock excludes the post-loop merge.
    void stopBatch()
    {
        if (!enabled_)
            return;
        batch_end_ = Clock::now();
    }

    __attribute__((always_inline)) inline OpStart startOperation() const
    {
        OpStart s{};
        if (!enabled_)
            return s;

        // Time is outer, counters inner — so the counter delta brackets only
        // the engine work (tight), while the time delta includes the rdpmc
        // pair (recalibrate via experiments/timer_latency/timer_floor with
        // the same BENCH_PERF_EVENTS to subtract the new floor).
        s.t = Clock::now();
        perf_.snapshot(s.counters.data());
        return s;
    }

    __attribute__((always_inline)) inline void endOperation(const OpStart &start)
    {
        if (!enabled_)
            return;

        std::array<std::uint64_t, PerfCounters::MAX_EVENTS> end_counters{};
        perf_.snapshot(end_counters.data());
        const auto t1 = Clock::now();

        latencies_ns_.push_back(static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - start.t).count()));
        for (std::size_t i = 0; i < perf_.event_count(); ++i)
            counter_samples_[i].push_back(end_counters[i] - start.counters[i]);
    }

    BenchmarkStats finishBatch()
    {
        if (enabled_)
            batch_end_ = Clock::now();
        return computeStats();
    }

    // Compute stats over whatever samples + span this runner currently holds,
    // WITHOUT re-stamping batch_end_. Use after the span has been set by
    // startBatch()/stopBatch() (or by merging) instead of finishBatch(), which
    // would overwrite batch_end_ with "now" and fold the merge into the span.
    BenchmarkStats stats() const { return computeStats(); }

    // Fold another runner's per-order samples into this one. Access control is
    // per-class, so this member may read `other`'s private buffers directly.
    //
    // Intentionally does NOT touch batch_start_/batch_end_: the wall-clock span
    // is owned by the aggregator (stamped via startBatch()/stopBatch()), not
    // derived from the per-thread runners. Only the latency (and perf-counter)
    // sample vectors are concatenated. Caller serializes concurrent merges.
    void merge(const BenchmarkRunner &other)
    {
        latencies_ns_.insert(latencies_ns_.end(),
                             other.latencies_ns_.begin(),
                             other.latencies_ns_.end());

        if (counter_samples_.size() < other.counter_samples_.size())
            counter_samples_.resize(other.counter_samples_.size());
        for (std::size_t i = 0; i < other.counter_samples_.size(); ++i)
            counter_samples_[i].insert(counter_samples_[i].end(),
                                       other.counter_samples_[i].begin(),
                                       other.counter_samples_[i].end());
    }

    void printStats(const BenchmarkStats &stats,
                    std::size_t event_count,
                    const std::string &event_label = "transactions") const
    {
        std::cerr << std::fixed << std::setprecision(3);
        std::cerr << "elapsed_ms=" << stats.elapsed_ms << '\n';
        std::cerr << "operations_per_sec=" << stats.operations_per_sec << '\n';
        std::cerr << "avg_latency_ns=" << stats.avg_latency_ns << '\n';
        std::cerr << "min_latency_ns=" << stats.min_latency_ns << '\n';
        std::cerr << "p50_latency_ns=" << stats.p50_latency_ns << '\n';
        std::cerr << "p95_latency_ns=" << stats.p95_latency_ns << '\n';
        std::cerr << "p99_latency_ns=" << stats.p99_latency_ns << '\n';
        std::cerr << "p99_9_latency_ns=" << stats.p999_latency_ns << '\n';
        std::cerr << "max_latency_ns=" << stats.max_latency_ns << '\n';
        std::cerr << event_label << '=' << event_count << '\n';

        for (std::size_t i = 0; i < perf_.event_count(); ++i)
            printCounterStats(perf_.name(i), counter_samples_[i]);

        maybeDumpRawCsv();
    }

private:
    static std::uint64_t percentile(std::vector<std::uint64_t> values, double p)
    {
        if (values.empty())
            return 0;
        const std::size_t idx = static_cast<std::size_t>(
            std::clamp(p, 0.0, 1.0) * static_cast<double>(values.size() - 1));
        std::nth_element(values.begin(), values.begin() + idx, values.end());
        return values[idx];
    }

    static void printCounterStats(const char *name, const std::vector<std::uint64_t> &samples)
    {
        if (samples.empty())
            return;

        std::uint64_t mn = std::numeric_limits<std::uint64_t>::max();
        std::uint64_t mx = 0;
        long double sum = 0.0L;
        for (auto v : samples)
        {
            sum += static_cast<long double>(v);
            if (v < mn)
                mn = v;
            if (v > mx)
                mx = v;
        }
        const double mean = static_cast<double>(sum / samples.size());

        std::cerr << name << "_avg=" << mean << '\n';
        std::cerr << name << "_min=" << mn << '\n';
        std::cerr << name << "_p50=" << percentile(samples, 0.50) << '\n';
        std::cerr << name << "_p95=" << percentile(samples, 0.95) << '\n';
        std::cerr << name << "_p99=" << percentile(samples, 0.99) << '\n';
        std::cerr << name << "_p99_9=" << percentile(samples, 0.999) << '\n';
        std::cerr << name << "_max=" << mx << '\n';
    }

    BenchmarkStats computeStats() const
    {
        const double elapsed_ns = static_cast<double>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(batch_end_ - batch_start_).count());
        const double elapsed_sec = elapsed_ns / 1e9;

        std::uint64_t min_lat = std::numeric_limits<std::uint64_t>::max();
        std::uint64_t max_lat = 0;
        double total_lat = 0.0;
        for (std::uint64_t lat : latencies_ns_)
        {
            total_lat += static_cast<double>(lat);
            if (lat < min_lat)
                min_lat = lat;
            if (lat > max_lat)
                max_lat = lat;
        }

        BenchmarkStats s{};
        s.elapsed_ms = elapsed_ns / 1e6;
        s.operations_per_sec = elapsed_sec > 0.0
                                   ? static_cast<double>(latencies_ns_.size()) / elapsed_sec
                                   : 0.0;
        s.avg_latency_ns = latencies_ns_.empty()
                               ? 0.0
                               : total_lat / static_cast<double>(latencies_ns_.size());
        s.min_latency_ns = latencies_ns_.empty() ? 0 : min_lat;
        s.p50_latency_ns = percentile(latencies_ns_, 0.50);
        s.p95_latency_ns = percentile(latencies_ns_, 0.95);
        s.p99_latency_ns = percentile(latencies_ns_, 0.99);
        s.p999_latency_ns = percentile(latencies_ns_, 0.999);
        s.max_latency_ns = max_lat;
        return s;
    }

    void maybeDumpRawCsv() const
    {
        const char *path = std::getenv("BENCH_PERF_DUMP");
        if (!path || !*path || latencies_ns_.empty())
            return;

        std::FILE *fp = std::fopen(path, "w");
        if (!fp)
        {
            std::cerr << "[warn] BENCH_PERF_DUMP: cannot open " << path << '\n';
            return;
        }

        std::fprintf(fp, "latency_ns");
        for (std::size_t i = 0; i < perf_.event_count(); ++i)
            std::fprintf(fp, ",%s", perf_.name(i));
        std::fputc('\n', fp);

        const std::size_t n = latencies_ns_.size();
        for (std::size_t r = 0; r < n; ++r)
        {
            std::fprintf(fp, "%llu", static_cast<unsigned long long>(latencies_ns_[r]));
            for (std::size_t i = 0; i < perf_.event_count(); ++i)
                std::fprintf(fp, ",%llu",
                             static_cast<unsigned long long>(counter_samples_[i][r]));
            std::fputc('\n', fp);
        }
        std::fclose(fp);
        std::cerr << "[bench] raw per-order samples dumped to " << path << '\n';
    }

    bool enabled_;
    Clock::time_point batch_start_{};
    Clock::time_point batch_end_{};
    std::vector<std::uint64_t> latencies_ns_;
    PerfCounters perf_;
    std::vector<std::vector<std::uint64_t>> counter_samples_;
};

#endif
