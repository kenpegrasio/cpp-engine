# Learning Log

## 1

`const Order* order` implies `order` is a pointer to constant `Order` object. 

`Order* const order` implies `order` is a constant pointer to `Order` object. 

## 2

`-fsanitize=address` enables AddressSanitizer. This cannot be combined with `-fsanitize=thread` as mentioned in this [documentation](https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html). 

`-fsanitize=thread` enables the ThreadSanitizer. This cannot be combined with `-fsanitize=address` as mentioned in this [documentation](https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html). 

`-fsanitize=undefined` enables UndefinedBehaviorSanitizer. It catches selected runtime-checkable undefined behavior. 

Use `-fno-omit-frame-pointer` to improve stack traces. 

`-I<folder-name>` means you are telling the compiler to add the `folder-name` to the compiler's header search path. 

## 3

> Here's how a deque<Tp> manages memory.  Each deque has 4 members:
>    - Tp**        _M_map
>    - size_t      _M_map_size
>    - iterator    _M_start, _M_finish
>
>    map_size is at least 8.  %map is an array of map_size
>    pointers-to-@a nodes.  (The name %map has nothing to do with the
>    std::map class, and @b nodes should not be confused with
>    std::list's usage of @a node.)
>
>    A @a node has no specific type name as such, but it is referred
>    to as @a node in this file.  It is a simple array-of-Tp.  If Tp
>    is very large, there will be one Tp element per node (i.e., an
>    @a array of one).  For non-huge Tp's, node size is inversely
>    related to Tp size: the larger the Tp, the fewer Tp's will fit
>    in a node.  The goal here is to keep the total size of a node
>    relatively small and constant over different Tp's, to improve
>    allocator efficiency.
>
>    Not every pointer in the %map array will point to a node.  If
>    the initial number of elements in the deque is small, the
>    /middle/ %map pointers will be valid, and the ones at the edges
>    will be unused.  This same situation will arise as the %map
>    grows: available %map pointers, if any, will be on the ends.  As
>    new nodes are created, only a subset of the %map's pointers need
>    to be copied @a outward.

## 4

To update C++ Intellisense to syntax check according to the correct version:
1. Press Ctrl + Shift + P (or Cmd + Shift + P on Mac) to open the Command Palette.
2. Type and select C/C++: Edit Configurations (UI).
3. Scroll down to the C++ Standard dropdown field.
4. Select your desired version (e.g., c++20, c++23).

## 5

You cannot call `resize` in `std::vector<std::mutex>`. From the cppreference for `resize`, the following type requirements are stated:

> T must meet the requirements of MoveInsertable and DefaultInsertable in order to use overload (`void resize( size_type count );`).  
> T must meet the requirements of CopyInsertable in order to use overload (`void resize( size_type count, const value_type& value );`). 

Well, next question is that what is MoveInsertable?

> If std::allocator<T> or a similar allocator is used, a class does not have to implement a move constructor to satisfy this type requirement: a copy constructor that takes a const T& argument can bind rvalue expressions. If a MoveInsertable class implements a move constructor, it may also implement move semantics to take advantage of the fact that the value of rv after construction is unspecified. 

Basically, in short, the object must have either move constructor or copy constructor. However, the documentation for `std::mutex` itself states that it is neither copyable nor movable. That is why you cannot call `resize` in `std::vector<std::mutex>`. 

## 6

`perf_event_paranoid` gates the `perf_event_open()` syscall.

A kernel tracepoint is a predefined, static hook embedded directly into operating system source code. When enabled, it captures exact system events. All tracing happens in the kernel. perf_event_open enables the tracing necessarily. 

`/sys/kernel/tracing/events` is a phone book, where you will look up the id of the system events. By default, access to this folder is root only, so you to need to run the following command to give access:

```bash
sudo chmod -R o+r /sys/kernel/tracing/events
```

## 7 

- No system call, i.e., `futex(FUTEX_WAIT)`, will be made when the `pred` in `cv.wait(lock, pred)` is true. 
- No system call, i.e., `futex(FUTEX_WAKE)`, will be made when nobody is registered as a waiter


## 8 

```c++
void push(const T &value)
{
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push(value);
    cond_var_.notify_one();
}
```

`mutex_` will be hold when `cond_var_.notify_one()` perform system calls. This will limit concurrency :) 

## 9

```bash
for d in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
  c=$(basename "$(dirname "$d")")
  printf "%-6s cur=%7.0f MHz  min=%5.0f  max=%5.0f  gov=%s\n" "$c" \
    "$(( $(cat $d/scaling_cur_freq) / 1000 ))" \
    "$(( $(cat $d/cpuinfo_min_freq) / 1000 ))" \
    "$(( $(cat $d/cpuinfo_max_freq) / 1000 ))" \
    "$(cat $d/scaling_governor)"
done
```

```
cpu0   cur=   1600 MHz  min=  400  max= 4700  gov=powersave
cpu10  cur=    400 MHz  min=  400  max= 4700  gov=powersave
cpu11  cur=    400 MHz  min=  400  max= 4700  gov=powersave
cpu12  cur=   1300 MHz  min=  400  max= 3600  gov=powersave
cpu13  cur=   1200 MHz  min=  400  max= 3600  gov=powersave
cpu14  cur=   1399 MHz  min=  400  max= 3600  gov=powersave
cpu15  cur=   1374 MHz  min=  400  max= 3600  gov=powersave
cpu1   cur=   1288 MHz  min=  400  max= 4700  gov=powersave
cpu2   cur=    475 MHz  min=  400  max= 4700  gov=powersave
cpu3   cur=    809 MHz  min=  400  max= 4700  gov=powersave
cpu4   cur=    400 MHz  min=  400  max= 4900  gov=powersave
cpu5   cur=    400 MHz  min=  400  max= 4900  gov=powersave
cpu6   cur=    400 MHz  min=  400  max= 4900  gov=powersave
cpu7   cur=   1277 MHz  min=  400  max= 4900  gov=powersave
cpu8   cur=   1343 MHz  min=  400  max= 4700  gov=powersave
cpu9   cur=    755 MHz  min=  400  max= 4700  gov=powersave
```

## 10

```bash
mpstat -P ALL 2 1
```

## 11

```bash
perf stat -e cpu_core/l2_request.all/,cpu_core/l2_request.miss/   ./engine_v6b --benchmark --N 2 --shard 64 < tests/generated_shards/multi_64_uniform_wide_range.txt   > b64.txt 2>&1

# cache-line ping-pong between cores — THE key metric
perf stat -e cpu_core/ocr.demand_data_rd.l3_hit.snoop_hitm/,cpu_core/ocr.demand_rfo.l3_hit.snoop_hitm/ \
  ./engine_v6b --benchmark --N 2 --shard 64 < tests/generated_shards/multi_64_uniform_wide_range.txt

# L3 capacity / DRAM pressure (shows this is NOT the mechanism)
perf stat -e cpu_core/longest_lat_cache.reference/,cpu_core/longest_lat_cache.miss/ ...

# which specific cache lines and source lines are ping-ponging
perf c2c record -- ./engine_v6b --benchmark --N 2 --shard 64 < tests/generated_shards/multi_64_uniform_wide_range.txt
perf c2c report --stdio
```

