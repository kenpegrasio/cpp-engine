#ifndef UTILS_HPP
#define UTILS_HPP

#include "types.hpp"
#include "constants.hpp"

#include <cstring>
#include <vector>

std::vector<std::vector<Order>> splitOrders(std::vector<Order> &orders, int N)
{
    std::vector<std::vector<Order>> res(N);
    for (int i = 0; i < orders.size(); i++)
    {
        res[i % N].push_back(orders[i]);
    }
    return res;
}

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

#endif