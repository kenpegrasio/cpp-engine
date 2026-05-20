#ifndef PARSER_HPP
#define PARSER_HPP

#include "types.hpp"

#include <iostream>
#include <vector>
#include <memory>

inline std::vector<Order> parseOrders()
{
    int number_of_orders;
    std::cin >> number_of_orders;
    std::vector<Order> orders(number_of_orders);
    for (int i = 0; i < number_of_orders; i++)
    {
        int seq_id;
        char order_type;
        unsigned int count;
        unsigned long long price;
        std::cin >> seq_id >> order_type >> count >> price;
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

#endif
