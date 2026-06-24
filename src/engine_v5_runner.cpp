#include "benchmark.hpp"
#include "types.hpp"
#include "parser.hpp"
#include "utils.hpp"
#include "core_allocator.hpp"
#include "engines.hpp"

#include <map>
#include <deque>
#include <thread>
#include <barrier>

std::mutex merge_mtx;

bool benchmark_mode = false;

int main(int argc, char **argv)
{
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(nullptr);

    int N = NUMBER_OF_PHYSICAL_P_CORES; // default number of threads, can be overridden by command line argument
    for (int i = 1; i < argc; i++)
    {
        if (std::string(argv[i]) == "--benchmark")
            benchmark_mode = true;
        if (std::string(argv[i]) == "--N")
        {
            if (i + 1 < argc)
            {
                N = std::stoi(argv[i + 1]);
                if (N > NUMBER_OF_PHYSICAL_P_CORES && N <= 2 * NUMBER_OF_PHYSICAL_P_CORES)
                {
                    std::cerr << "Warning: N is greater than the number of physical P-cores. Threads is placed on hyperthread siblings and may share the same resources, like L1/L2 cache" << std::endl;
                }
                if (N > 2 * NUMBER_OF_PHYSICAL_P_CORES)
                {
                    std::cerr << "Warning: N is greater than or equal to the number of logical CPUs. Performance may be degraded due to time-slicing." << std::endl;
                }
                i++;
            }
            else
            {
                std::cerr << "Error: --N option requires an argument." << std::endl;
                return EXIT_FAILURE;
            }
        }
    }

    std::vector<Order> orders = parseOrders();
    std::vector<std::vector<Order>> split_orders = splitOrders(orders, N);
    for (int i = 0; i < N; i++)
    {
        // assume that each thread has at least one order to process
        if (split_orders[i].empty())
        {
            std::cerr << "[error] thread " << i << " has no orders to process\n";
            return 1;
        }
    }

    EngineV5 engine;

    BenchmarkRunner agg(benchmark_mode);
    std::barrier sync_start(N, [&]() noexcept
                            { agg.startBatch(); });
    std::barrier sync_end(N, [&]() noexcept
                          { agg.stopBatch(); });
    agg.reserve(orders.size());
    engine.logs.reserve(orders.size() * 2);

    CoreAllocator core_allocator;

    auto worker = [&](int i)
    {
        pin_to_core(core_allocator.allocate());
        BenchmarkRunner benchmark(benchmark_mode);
        benchmark.reserve(split_orders[i].size());

        // Wait for all threads to start before processing orders to ensure a fair benchmark
        sync_start.arrive_and_wait();

        for (const auto &order : split_orders[i])
        {
            const auto order_start = benchmark.startOperation();
            engine.process(order);
            benchmark.endOperation(order_start);
        }

        // Wait for all threads to finish processing orders before finalizing the benchmark
        sync_end.arrive_and_wait();

        if (benchmark_mode)
        {
            std::lock_guard<std::mutex> lock(merge_mtx);
            agg.merge(benchmark);
        }
    };

    std::vector<std::thread> workers;
    for (int i = 0; i < N; i++)
    {
        workers.push_back(std::thread(worker, i));
    }

    for (auto &thread : workers)
    {
        thread.join();
    }

    if (benchmark_mode)
    {
        const BenchmarkStats stats = agg.stats();
        agg.printStats(stats, engine.logs.size());
        return EXIT_SUCCESS;
    }

    std::cout << engine.logs.size() << std::endl;
    for (const auto &log : engine.logs)
    {
        if (log.log_type == LogType::Receive)
        {
            const auto &order = log.order;
            std::cout << "Receive " << order.order_id << " " << (char)order.order_side << " " << order.count << " " << order.price << std::endl;
        }
        else if (log.log_type == LogType::Match)
        {
            const auto &transaction = log.transaction;
            std::cout << "Match " << transaction.count << " " << transaction.buy_order_id << " " << transaction.sell_order_id << std::endl;
        }
    }
}