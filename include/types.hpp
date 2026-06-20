#ifndef TYPES_HPP
#define TYPES_HPP

enum OrderSide
{
    Buy = 'B',
    Sell = 'S'
};

struct Order
{
    int order_id;
    OrderSide order_side;
    unsigned int count;
    unsigned long long price;

    Order() {}

    Order(int new_order_id, OrderSide new_order_type,
          unsigned int new_count, unsigned long long new_price)
        : order_id{new_order_id},
          order_side{new_order_type},
          count{new_count},
          price{new_price} {}
};

// Only used in single-threaded, order_id is used to describe the order arrival time
struct BidComparator
{
    // When bidding, higher prices will win. If same price, prioritize the first who bid
    bool operator()(const Order &a, const Order &b) const
    {
        if (a.price != b.price)
            return a.price < b.price;
        return a.order_id > b.order_id;
    }
};

// Only used in single-threaded, order_id is used to describe the order arrival time
struct BidPointerComparator
{
    bool operator()(const Order *a, const Order *b) const
    {
        if (a->price != b->price)
            return a->price < b->price;
        return a->order_id > b->order_id;
    }
};

// Only used in single-threaded, order_id is used to describe the order arrival time
struct AskComparator
{
    // When asking, lower prices will win. If same price, prioritize the first who ask
    bool operator()(const Order &a, const Order &b) const
    {
        if (a.price != b.price)
            return a.price > b.price;
        return a.order_id > b.order_id;
    }
};

// Only used in single-threaded, order_id is used to describe the order arrival time
struct AskPointerComparator
{
    bool operator()(const Order *a, const Order *b) const
    {
        if (a->price != b->price)
            return a->price > b->price;
        return a->order_id > b->order_id;
    }
};

// For checking single-thread
struct Transaction
{
    int buy_order_id;
    int sell_order_id;
    int count;

    Transaction() {}

    Transaction(int new_buy_order_id, int new_sell_order_id, int new_count)
        : buy_order_id{new_buy_order_id},
          sell_order_id{new_sell_order_id},
          count{new_count} {}
};

// For checking multi-thread
enum LogType
{
    Receive,
    Match
};

struct Log
{
    LogType log_type;
    // For Receive
    Order order;
    // For Match
    Transaction transaction;

    Log(LogType new_log_type, const Order &new_order)
        : log_type{new_log_type},
          order{new_order} {}

    Log(LogType new_log_type, const Transaction &new_transaction)
        : log_type{new_log_type},
          transaction{new_transaction} {}
};

#endif
