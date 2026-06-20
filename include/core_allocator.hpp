#ifndef CORE_ALLOCATOR_HPP
#define CORE_ALLOCATOR_HPP

#include "constants.hpp"

#include <atomic>

class CoreAllocator
{
private:
    std::atomic<int> num_threads_allocated{0};
    /*
        In the current machine of interest, there are 6 physical P-cores, each with 2 logical CPUs (hyperthreading), for a total of 12 logical CPUs.
        The core_order array is designed to allocate threads to physical cores first before using hyperthread siblings, which can help
        improve performance by reducing contention for shared resources like L1/L2 cache.
    */
    int core_order[2 * NUMBER_OF_PHYSICAL_P_CORES] = {0, 2, 4, 6, 8, 10, 1, 3, 5, 7, 9, 11};

public:
    int allocate()
    {
        int idx = num_threads_allocated.fetch_add(1, std::memory_order_relaxed);
        return core_order[idx % (2 * NUMBER_OF_PHYSICAL_P_CORES)];
    }
};

#endif