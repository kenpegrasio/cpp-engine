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

The experiments are conducted on a **13th Gen Intel® Core™ i7-13620H processor**. According to the [processor specification](https://www.intel.com/content/www/us/en/products/sku/232130/intel-core-i713620h-processor-24m-cache-up-to-4-90-ghz/specifications.html), it contains six Performance cores (P-cores), four Efficient cores (E-cores), and sixteen hardware threads in total.

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

Constructing the worker threads introduces setup costs that are unrelated to the performance of the matching engine. For example, the implementation must create a thread of execution, prepare the callable and its arguments, and associate the new thread with the corresponding `std::thread` object. Because the worker threads are constructed sequentially by the main thread, earlier workers may also become ready before later workers have been created.

<details markdown="1">
<summary>More on Thread Constructor</summary>

### Thread Constructor

To understand deeper on what happen underneath the hood, we examine the following `std::thread` constructor in greater detail:

```c++
template<class F, class... Args>
explicit thread(F&& f, Args&&... args);
```

There are four major events that happen during construction, they are **Forwarding Reference**, **Decay Copy**, **Internal Thread State**, **Function Invocation**. 

#### Forwarding Reference

Observe that the constructor uses the forwarding reference for `f` and `args`. In general, this is used to preserve the lvalueness and rvalueness of a variable. More about forward can be found in this [cppreference page](https://en.cppreference.com/cpp/utility/forward). 

From the C++ Standard 13.10.3.2.3 ([link](https://eel.is/c++draft/temp.deduct.call#3)), the following is mentioned. 

> If P is a forwarding reference and the argument is an lvalue, the type “lvalue reference to A” is used in place of A for type deduction.

Because of this, when `f` is a lvalue of function type, function-to-pointer conversion will not be implicitly performed. The lvalue reference function type will be used instead. 

Moreover, the `explicit` keyword also aligned with this, i.e., it make sure that implicit conversion will not occur. 

#### Decay Copy (until C++23)

After being forwarded, `std::forward<F>(f)` will have the type: lvalue reference function type. Notice that this is not movable. 

> *Sneak peek*: This should be movable because it will be moved from the interal thread state to the INVOKE or `std::invoke`. 

Because of this, decay copy is required. The lvalue reference function type will be decayed to function pointer. More on decay can be found in the following [cppreference](https://en.cppreference.com/cpp/types/decay). 

Other than this, passing an array into the constructor now become possible thanks to decay copy. 

It is also wonderful to observe that the calls up to decay copy are evaluated in the main thread. Therefore, exceptions thrown during the evaluation will be thrown in the current thread without starting the new thread. 

#### Internal Thread State

It is important to notice that the "step" in forwarding reference and decay copy is just for constructing the thread object. The thread of execution has not been started yet. 

Logically, constructing the object means that the state being passed through the constructor, i.e., `f` and `args` need to be stored somewhere in the internal state of the object. 

Indeed, the prvalue produced by the decay-copy will be stored in the internal state of the thread. 

#### Function Invocation

When invoking the function, this is where the thread of execution started to run. The internal thread state will be moved to the INVOKE (until C++23) or `std::invoke` (since C++23). 

> Question: Why not just copy everything?

For efficiency, most of the time, it is more efficient to move than to copy the whole thing. 

#### References
- Core reference: [cppreference thread](https://en.cppreference.com/cpp/thread/thread/thread) 
- [C++ Standard 13.10.3.2.3](https://eel.is/c++draft/temp.deduct.call#3)
- [Decay Copy](https://en.cppreference.com/cpp/standard_library/decay-copy) and [Decay](https://en.cppreference.com/cpp/types/decay)
</details>

Including these activities in the measured interval would make the result dependent on thread-creation overhead rather than solely on the concurrent execution of the matching engine. The benchmark therefore uses two synchronization barriers to define the beginning and end of the measured workload:

```c++
std::barrier sync_start(N, [&]() noexcept { agg.startBatch(); });
std::barrier sync_end(N, [&]() noexcept { agg.stopBatch(); });
```

> More on the `agg.startBatch()` and `agg.stopBatch()` on [Result Aggregation](1_benchmark.md#result-aggregation)

Each worker performs its required initialization, including thread pinning and performance-counter setup, before arriving at `sync_start`. A worker that arrives early remains blocked until all `N` workers have reached the barrier.

When the final worker arrives, the barrier executes its completion function. The workers are released only after this completion function has finished. Consequently, no worker can begin processing orders before every worker is ready.

The barrier does not guarantee that all workers execute their first instruction at exactly the same instant. Their execution can still be affected by operating-system scheduling. Instead, it establishes a common release point and prevents differences in thread-construction and initialization time from affecting the measurement.

After processing its assigned orders, each worker arrives at `sync_end`. Workers that finish early wait at the barrier while the remaining workers continue processing. When the final worker arrives, the barrier executes the completion function before releasing the waiting workers, ensuring that threads which finish early do not proceed to execute other work that could introduce additional latency or scheduling effects into the measurement.

## Result Aggregation 

The existing `BenchmarkRunner` was originally designed for a single-threaded matching engine. Each instance records the measurements produced by one benchmark thread and does not provide synchronization for combining results from multiple threads. 

To reuse this class in the multithreaded benchmarks, each worker thread is assigned its own `BenchmarkRunner` instance. After all workers have completed their workloads, their recorded measurements are merged into a separate aggregate runner, denoted as `agg`.

The relevant internal state of `BenchmarkRunner` is shown below:

```c++
class BenchmarkRunner {
private:
    bool enabled_;
    Clock::time_point batch_start_{};
    Clock::time_point batch_end_{};
    std::vector<std::uint64_t> latencies_ns_;
    PerfCounters perf_;
    std::vector<std::vector<std::uint64_t>> counter_samples_;
};
```

Not every field should be combined in the same manner.

The `PerfCounters` object itself is not merged because it represents the live performance-counter state associated with a particular worker thread. Each thread must configure, start, and read its own counters independently. However, the completed counter measurements stored in `counter_samples_` can be merged after execution.

Similarly, all operation-latency samples stored in `latencies_ns_` are combined into a single collection. This allows latency statistics, such as the median and tail percentiles, to be computed across all operations processed by all worker threads.

The following method appends the latency and performance-counter samples from another runner:

```c++
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
```

The batch start and end timestamps require different treatment. Per-thread execution times should not be summed because the worker threads execute concurrently. Instead, `batch_start_` and `batch_end_` must capture the wall-clock interval during which the entire multithreaded workload is executed.

Two synchronization barriers are used to establish this interval:

```c++
std::barrier sync_start(N, [&]() noexcept { agg.startBatch(); });
std::barrier sync_end(N, [&]() noexcept { agg.stopBatch(); });
```

Before processing any orders, every worker arrives at `sync_start`. The barrier completion function invokes `agg.startBatch()` after all workers have arrived. After completing its assigned workload, each worker arrives at `sync_end`. When the final worker reaches the barrier, the completion function invokes `agg.stopBatch()`. 
