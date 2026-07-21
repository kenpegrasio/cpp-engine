#include "engines.hpp"

void EngineV6B::process(const Order &order)
{
    int shard_id = order.shard_id;
    std::lock_guard<std::mutex> lock(shard_mutexes[shard_id].mtx);
    engines[shard_id].receive(order);
    engines[shard_id].match();
}