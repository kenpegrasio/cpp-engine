#include "engines.hpp"
#include "constants.hpp"

/*
class EngineV5
{
private:
    std::array<std::deque<Order>, MAX_PRICE + 1> bids;
    std::array<std::deque<Order>, MAX_PRICE + 1> asks;
    std::array<std::mutex, MAX_PRICE + 1> bids_mutex;
    std::array<std::mutex, MAX_PRICE + 1> asks_mutex;
    std::mutex matching_mutex;
    std::shared_mutex top_bids_mutex, lowest_asks_mutex;
    int top_bids{-1}, lowest_asks{MAX_PRICE + 1};
    std::atomic<int> interior_insert{0};
    std::atomic<bool> is_matching{false};
    void match();

public:
    std::vector<Log> logs;
    void process(const Order &order);
};
*/

void EngineV5::match()
{
    if (top_bids < lowest_asks)
        return;
    is_matching.store(true, std::memory_order_seq_cst);
    while (interior_insert.load(std::memory_order_seq_cst) != 0)
        ;
    // Matching logic
    while (top_bids >= lowest_asks)
    {
        // No need fine grained lock here because the lock protecting this is fine-grained, interior_insert has all been exhausted
        auto &highest_buy_order = bids[top_bids].front();
        auto &lowest_sell_order = asks[lowest_asks].front();
        if (highest_buy_order.count > lowest_sell_order.count)
        {
            highest_buy_order.count -= lowest_sell_order.count;
            {
                std::lock_guard<std::mutex> logs_lock{logs_mutex};
                logs.push_back(Log(LogType::Match,
                                   Transaction(
                                       highest_buy_order.order_id,
                                       lowest_sell_order.order_id,
                                       lowest_sell_order.count)));
            }
            asks[lowest_asks].pop_front();
            while (lowest_asks <= MAX_PRICE && asks[lowest_asks].empty())
                lowest_asks++;
        }
        else if (highest_buy_order.count < lowest_sell_order.count)
        {
            lowest_sell_order.count -= highest_buy_order.count;
            {
                std::lock_guard<std::mutex> logs_lock{logs_mutex};
                logs.push_back(Log(LogType::Match,
                                   Transaction(
                                       highest_buy_order.order_id,
                                       lowest_sell_order.order_id,
                                       highest_buy_order.count)));
            }
            bids[top_bids].pop_front();
            while (top_bids >= 1 && bids[top_bids].empty())
                top_bids--;
        }
        else
        {
            {
                std::lock_guard<std::mutex> logs_lock{logs_mutex};
                logs.push_back(Log(LogType::Match,
                                   Transaction(
                                       highest_buy_order.order_id,
                                       lowest_sell_order.order_id,
                                       highest_buy_order.count)));
            }
            asks[lowest_asks].pop_front();
            while (lowest_asks <= MAX_PRICE && asks[lowest_asks].empty())
                lowest_asks++;
            bids[top_bids].pop_front();
            while (top_bids >= 1 && bids[top_bids].empty())
                top_bids--;
        }
    }
    is_matching.store(false, std::memory_order_seq_cst);
    return;
}

void EngineV5::process(const Order &order)
{
    switch (order.order_side)
    {
    case OrderSide::Sell:
    {
        if (!is_matching.load(std::memory_order_seq_cst))
        {
            std::shared_lock<std::shared_mutex> read_lock{lowest_asks_mutex};
            if (lowest_asks <= order.price)
            {
                interior_insert.fetch_add(1, std::memory_order_seq_cst);
                std::lock_guard<std::mutex> fine_grained_lock{asks_mutex[order.price]};
                {
                    std::lock_guard<std::mutex> logs_lock{logs_mutex};
                    logs.push_back(Log(LogType::Receive, order));
                }
                asks[order.price].push_back(order);
                interior_insert.fetch_sub(1, std::memory_order_seq_cst);
                break;
            }
        }
        std::scoped_lock lock{top_bids_mutex, lowest_asks_mutex, matching_mutex};
        {
            std::lock_guard<std::mutex> fine_grained_lock{asks_mutex[order.price]};
            {
                std::lock_guard<std::mutex> logs_lock{logs_mutex};
                logs.push_back(Log(LogType::Receive, order));
            }
            asks[order.price].push_back(order);
        }
        if (lowest_asks <= order.price)
            break;
        lowest_asks = order.price;
        match();
        break;
    }
    case OrderSide::Buy:
    {
        if (!is_matching.load(std::memory_order_seq_cst))
        {
            std::shared_lock<std::shared_mutex> read_lock{top_bids_mutex};
            if (top_bids >= order.price)
            {
                interior_insert.fetch_add(1, std::memory_order_seq_cst);
                std::lock_guard<std::mutex> fine_grained_lock{bids_mutex[order.price]};
                {
                    std::lock_guard<std::mutex> logs_lock{logs_mutex};
                    logs.push_back(Log(LogType::Receive, order));
                }
                bids[order.price].push_back(order);
                interior_insert.fetch_sub(1, std::memory_order_seq_cst);
                break;
            }
        }
        std::scoped_lock lock{top_bids_mutex, lowest_asks_mutex, matching_mutex};
        {
            std::lock_guard<std::mutex> fine_grained_lock{bids_mutex[order.price]};
            {
                std::lock_guard<std::mutex> logs_lock{logs_mutex};
                logs.push_back(Log(LogType::Receive, order));
            }
            bids[order.price].push_back(order);
        }
        if (top_bids >= order.price)
            break;
        top_bids = order.price;
        match();
        break;
    }
    }
}