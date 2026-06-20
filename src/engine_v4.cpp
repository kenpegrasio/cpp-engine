#include "benchmark.hpp"
#include "types.hpp"
#include "parser.hpp"
#include "utils.hpp"
#include "core_allocator.hpp"

#include <map>
#include <deque>
#include <thread>
#include <barrier>

std::map<unsigned long long, std::deque<Order>> bids;
std::map<unsigned long long, std::deque<Order>> asks;
std::mutex mtx, merge_mtx;

std::vector<Log> logs;

bool benchmark_mode = false;

void insertOrder(const Order &order)
{
    logs.push_back(Log(LogType::Receive, order));
    if (order.order_side == OrderSide::Buy)
        bids[order.price].push_back(order);
    else
        asks[order.price].push_back(order);
}

void matchOrders()
{
    auto highest_bid_entry = bids.rbegin();
    auto lowest_ask_entry = asks.begin();
    while (highest_bid_entry != bids.rend() && lowest_ask_entry != asks.end())
    {
        auto &highest_bid_deque = highest_bid_entry->second;
        auto &lowest_ask_deque = lowest_ask_entry->second;

        auto &highest_bid = highest_bid_deque.front();
        auto &lowest_ask = lowest_ask_deque.front();

        if (highest_bid.price < lowest_ask.price)
            break;

        if (highest_bid.count > lowest_ask.count)
        {
            highest_bid.count -= lowest_ask.count;
            logs.push_back(Log(LogType::Match,
                               Transaction(
                                   highest_bid.order_id,
                                   lowest_ask.order_id,
                                   lowest_ask.count)));
            lowest_ask_deque.pop_front();
            if (lowest_ask_deque.empty())
            {
                asks.erase(lowest_ask_entry);
                lowest_ask_entry = asks.begin();
            }
        }
        else if (highest_bid.count < lowest_ask.count)
        {
            lowest_ask.count -= highest_bid.count;
            logs.push_back(Log(LogType::Match,
                               Transaction(
                                   highest_bid.order_id,
                                   lowest_ask.order_id,
                                   highest_bid.count)));
            highest_bid_deque.pop_front();
            if (highest_bid_deque.empty())
            {
                bids.erase(std::next(highest_bid_entry).base());
                highest_bid_entry = bids.rbegin();
            }
        }
        else
        {
            logs.push_back(Log(LogType::Match,
                               Transaction(
                                   highest_bid.order_id,
                                   lowest_ask.order_id,
                                   highest_bid.count)));
            highest_bid_deque.pop_front();
            lowest_ask_deque.pop_front();
            if (highest_bid_deque.empty())
            {
                bids.erase(std::next(highest_bid_entry).base());
                highest_bid_entry = bids.rbegin();
            }
            if (lowest_ask_deque.empty())
            {
                asks.erase(lowest_ask_entry);
                lowest_ask_entry = asks.begin();
            }
        }
    }
}

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

    BenchmarkRunner agg(benchmark_mode);
    std::barrier sync_start(N, [&]() noexcept
                            { agg.startBatch(); });
    std::barrier sync_end(N, [&]() noexcept
                          { agg.stopBatch(); });
    agg.reserve(orders.size());
    logs.reserve(orders.size() * 2);

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
            {
                std::lock_guard<std::mutex> lock(mtx);
                insertOrder(order);
                matchOrders();
            }
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
        agg.printStats(stats, logs.size());
        return EXIT_SUCCESS;
    }

    std::cout << logs.size() << std::endl;
    for (const auto &log : logs)
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