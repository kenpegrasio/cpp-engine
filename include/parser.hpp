#ifndef PARSER_HPP
#define PARSER_HPP

#include "types.hpp"

#include <iostream>
#include <vector>
#include <memory>
#include <unordered_map>

inline std::vector<Order> parseOrders(std::istream &in = std::cin)
{
    int number_of_orders;
    in >> number_of_orders;
    std::vector<Order> orders(number_of_orders);
    for (int i = 0; i < number_of_orders; i++)
    {
        int seq_id;
        char order_type;
        unsigned int count;
        unsigned long long price;
        in >> seq_id >> order_type >> count >> price;
        if (order_type == 'B')
        {
            orders[i] = Order(seq_id, OrderSide::Buy, count, price);
        }
        else
        {
            orders[i] = Order(seq_id, OrderSide::Sell, count, price);
        }
    }
    return orders;
}

inline std::vector<Order *> parseOrdersToPointers()
{
    int number_of_orders;
    std::cin >> number_of_orders;
    std::vector<Order *> orders(number_of_orders);
    for (int i = 0; i < number_of_orders; i++)
    {
        int seq_id;
        char order_type;
        unsigned int count;
        unsigned long long price;
        std::cin >> seq_id >> order_type >> count >> price;
        if (order_type == 'B')
        {
            orders[i] = new Order(seq_id, OrderSide::Buy, count, price);
        }
        else
        {
            orders[i] = new Order(seq_id, OrderSide::Sell, count, price);
        }
    }
    return orders;
}

inline std::vector<Order> parseMultishardOrders(std::istream &in = std::cin)
{
    // Build unordered map for shard
    int number_of_shards;
    in >> number_of_shards;
    std::unordered_map<std::string, int> shard_map;
    for (int i = 0; i < number_of_shards; i++)
    {
        std::string shard_code;
        in >> shard_code;
        shard_map[shard_code] = i;
    }

    // Build orders
    int number_of_orders;
    in >> number_of_orders;
    std::vector<Order> orders(number_of_orders);
    for (int i = 0; i < number_of_orders; i++)
    {
        int seq_id;
        std::string shard_code;
        char order_type;
        unsigned int count;
        unsigned long long price;
        in >> seq_id >> shard_code >> order_type >> count >> price;
        if (order_type == 'B')
        {
            orders[i] = Order(seq_id, shard_map[shard_code], OrderSide::Buy, count, price);
        }
        else
        {
            orders[i] = Order(seq_id, shard_map[shard_code], OrderSide::Sell, count, price);
        }
    }
    return orders;
}

#endif
