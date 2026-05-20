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

struct BidPointerComparator
{
    bool operator()(const Order *a, const Order *b) const
    {
        if (a->price != b->price)
            return a->price < b->price;
        return a->order_id > b->order_id;
    }
};

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

struct AskPointerComparator
{
    bool operator()(const Order *a, const Order *b) const
    {
        if (a->price != b->price)
            return a->price > b->price;
        return a->order_id > b->order_id;
    }
};

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

#endif
