#include "benchmark.hpp"
#include "types.hpp"
#include "parser.hpp"
#include "utils.hpp"
#include "core_allocator.hpp"
#include "engines.hpp"
#include "multishard_utils.hpp"

#include <map>
#include <deque>
#include <thread>
#include <barrier>

bool benchmark_mode = false;

int main(int argc, char **argv)
{
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(nullptr);

    int N = NUMBER_OF_PHYSICAL_P_CORES; // default number of threads, can be overridden by command line argument
    int shard_count = MAX_SHARDS;       // default number of shards, can be overridden by command line argument
    updateN(argc, argv, N);
    updateShards(argc, argv, shard_count);
    updateMode(argc, argv, benchmark_mode);

    const int worker_count = N + shard_count;
    printWorkerWarning(worker_count);

    auto orders = parseMultishardOrders();
    std::vector<std::vector<Order>> split_orders = splitOrders(orders, N);

    run<EngineV6A>(N, shard_count, worker_count, benchmark_mode, split_orders, orders);
}