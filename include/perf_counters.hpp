#ifndef PERF_COUNTERS_HPP
#define PERF_COUNTERS_HPP

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

class PerfCounters
{
public:
    static constexpr std::size_t MAX_EVENTS = 6;

    struct EventSpec
    {
        std::uint32_t type;
        std::uint64_t config;
        const char *name;
    };

    static EventSpec event_cache_misses() noexcept
    {
        return {PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES, "cache-misses"};
    }

    static EventSpec event_llc_load_misses() noexcept
    {
        return {PERF_TYPE_HW_CACHE,
                (PERF_COUNT_HW_CACHE_LL) |
                    (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                    (PERF_COUNT_HW_CACHE_RESULT_MISS << 16),
                "LLC-load-misses"};
    }

    static EventSpec event_dtlb_load_misses() noexcept
    {
        return {PERF_TYPE_HW_CACHE,
                (PERF_COUNT_HW_CACHE_DTLB) |
                    (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                    (PERF_COUNT_HW_CACHE_RESULT_MISS << 16),
                "dTLB-load-misses"};
    }

    static EventSpec event_instructions() noexcept
    {
        return {PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS, "instructions"};
    }

    static EventSpec event_cpu_cycles() noexcept
    {
        return {PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES, "cpu-cycles"};
    }

    PerfCounters() = default;
    PerfCounters(const PerfCounters &) = delete;
    PerfCounters &operator=(const PerfCounters &) = delete;

    ~PerfCounters()
    {
        for (std::size_t i = 0; i < event_count_; ++i)
        {
            if (pages_[i])
                ::munmap(pages_[i], page_size_);
            if (fds_[i] >= 0)
                ::close(fds_[i]);
        }
    }

    void open(const std::vector<EventSpec> &events)
    {
        if (events.size() > MAX_EVENTS)
            throw std::runtime_error("PerfCounters: too many events (max " +
                                     std::to_string(MAX_EVENTS) + ")");

        page_size_ = static_cast<std::size_t>(::sysconf(_SC_PAGESIZE));

        for (const auto &e : events)
        {
            perf_event_attr attr{};
            attr.size = sizeof(attr);
            attr.type = e.type;
            attr.config = e.config;
            attr.disabled = 0;
            attr.exclude_kernel = 1;
            attr.exclude_hv = 1;

            const int fd = static_cast<int>(
                ::syscall(SYS_perf_event_open, &attr, 0 /*self*/, -1 /*any cpu*/, -1, 0));
            if (fd < 0)
                throw std::runtime_error(std::string("perf_event_open failed for ") + e.name +
                                         " — check /proc/sys/kernel/perf_event_paranoid");

            void *p = ::mmap(nullptr, page_size_, PROT_READ, MAP_SHARED, fd, 0);
            if (p == MAP_FAILED)
            {
                ::close(fd);
                throw std::runtime_error(std::string("mmap failed for ") + e.name);
            }

            names_[event_count_] = e.name;
            fds_[event_count_] = fd;
            pages_[event_count_] = static_cast<perf_event_mmap_page *>(p);
            ++event_count_;
        }
    }

    std::size_t event_count() const noexcept { return event_count_; }
    const char *name(std::size_t i) const noexcept { return names_[i]; }

    // Userspace counter read: rdpmc + offset from the mmap page, retried under
    // the kernel's seqlock to detect any reschedule between reads.
    __attribute__((always_inline)) inline std::uint64_t
    read_one(std::size_t i) const noexcept
    {
        auto *p = pages_[i];
        std::uint64_t val;
        std::uint32_t seq;
        do
        {
            seq = p->lock;
            asm volatile("" ::: "memory");

            const std::uint32_t idx = p->index;
            const std::int64_t offset = p->offset;

            if (idx == 0)
            {
                val = static_cast<std::uint64_t>(offset);
            }
            else
            {
                std::uint32_t lo, hi;
                asm volatile("rdpmc" : "=a"(lo), "=d"(hi) : "c"(idx - 1));
                val = ((static_cast<std::uint64_t>(hi) << 32) | lo) +
                      static_cast<std::uint64_t>(offset);
            }

            asm volatile("" ::: "memory");
        } while (p->lock != seq);
        return val;
    }

    __attribute__((always_inline)) inline void
    snapshot(std::uint64_t *out) const noexcept
    {
        for (std::size_t i = 0; i < event_count_; ++i)
            out[i] = read_one(i);
    }

private:
    std::size_t event_count_ = 0;
    std::size_t page_size_ = 0;
    std::array<int, MAX_EVENTS> fds_{{-1, -1, -1, -1, -1, -1}};
    std::array<perf_event_mmap_page *, MAX_EVENTS> pages_{};
    std::array<const char *, MAX_EVENTS> names_{};
};

#endif
