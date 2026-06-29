# Benchmark 

In the [previous phase](../single_thread/1_benchmark_controls.md), several single-shard single-threaded matching engine designs have been thoroughly examined. In this phase, these designs are extended to single-shard multithreaded matching engines. This extension requires several modification on the benchmark controls, which will be discussed on this page. 

## Unchanged Benchmark Controls

The following benchmark controls are carried over from the single-threaded experiments without modification:

1. [CPU Frequency Scaling Governer](../single_thread/1_benchmark_controls.md#cpu-frequency-scaling-governor)
2. [Frequency Boosting](../single_thread/1_benchmark_controls.md#frequency-boosting)
3. [Other Setup](../single_thread/1_benchmark_controls.md#other-setup)

## Thread Pinning and CPU Topology

The single-threaded experiments required only one benchmark thread to be pinned to a logical CPU. In the multithreaded experiments, however, the placement of every participating thread must be controlled explicitly.

Without explicit thread affinity, the operating system may migrate threads between logical CPUs during execution. Such migrations can affect cache locality and introduce additional variation into the benchmark results. Furthermore, assigning multiple threads to arbitrary logical CPUs does not necessarily maximize physical parallelism, because some logical CPUs may be hardware threads belonging to the same physical core.

The experiments are conducted on a 13th Gen Intel® Core™ i7-13620H processor. According to the [processor specification](https://www.intel.com/content/www/us/en/products/sku/232130/intel-core-i713620h-processor-24m-cache-up-to-4-90-ghz/specifications.html), it contains six Performance cores (P-cores), four Efficient cores (E-cores), and sixteen hardware threads in total.

Because the processor uses a hybrid architecture, its CPU topology must be examined before selecting the logical CPUs used by the benchmark. The processor specification provides the overall core configuration, while the Linux topology information provides the mapping between physical cores and logical CPU IDs.

The following command displays the logical CPUs that belong to the same physical core:

```bash
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    echo "$(basename "$c"): $(cat "$c/topology/thread_siblings_list")"
done
```

Logical CPUs listed together are hardware threads of the same physical core. Therefore, assigning benchmark threads to different sibling groups ensures that they execute on separate physical cores.

On systems that expose separate performance-monitoring units for Intel P-cores and E-cores, the logical CPUs associated with each core type can be inspected using:

```bash
cat /sys/bus/event_source/devices/cpu_core/cpus
cat /sys/bus/event_source/devices/cpu_atom/cpus
```

The first command reports the logical CPUs associated with the P-cores, while the second reports those associated with the E-cores.

> **What are the differences between P-cores and E-cores?** P-cores and E-cores are designed for different purposes and consequently have different performance characteristics. P-cores are optimized for high single-threaded performance, whereas E-cores are optimized for power-efficient throughput. They may differ in clock frequency, microarchitecture, execution resources, and simultaneous multithreading support. Mixing both core types within the same experiment would therefore make the scaling results more difficult to interpret. To maintain a homogeneous execution environment, only P-cores are used throughout the experiments. Further information is available in this [article](https://www.supermicro.com/en/glossary/e-cores-p-cores). 

Based on this topology, the benchmark threads are pinned to distinct physical P-cores. Core assignment and thread pinning is implemented using the `CoreAllocator` and the `pin_to_core` function. 

```c++
class CoreAllocator
{
private:
    std::atomic<int> num_threads_allocated{0};
    int core_order[2 * NUMBER_OF_PHYSICAL_P_CORES] = {0, 2, 4, 6, 8, 10, 1, 3, 5, 7, 9, 11};

public:
    int allocate()
    {
        int idx = num_threads_allocated.fetch_add(1, std::memory_order_relaxed);
        return core_order[idx % (2 * NUMBER_OF_PHYSICAL_P_CORES)];
    }
};

bool pin_to_core(int core)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(core, &set);

    const int rc = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    if (rc != 0)
    {
        std::cerr << "[warn] pin to core " << core << " failed: " << strerror(rc) << std::endl;
        return false;
    }
    return true;
}
```

The `core_order` array determines the order in which logical CPUs are assigned to benchmark threads. The first six entries correspond to one logical CPU from each physical P-core. Consequently, the first six benchmark threads are placed on separate physical cores, preventing them from competing for the execution resources of the same core.

If more than six threads are allocated, the remaining entries assign threads to the sibling logical CPUs of those P-cores. These threads share physical-core resources with the first six threads and therefore do not provide the same degree of additional parallelism as threads placed on separate physical cores.

This allocation order allows the benchmark to use all available physical P-cores before enabling simultaneous multithreading on any of them.

## Synchronization Barriers 

## Result Aggregation 

