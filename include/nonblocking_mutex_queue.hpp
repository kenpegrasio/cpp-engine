#ifndef NONBLOCKING_MUTEX_QUEUE_HPP
#define NONBLOCKING_MUTEX_QUEUE_HPP

#include <queue>
#include <mutex>
#include <condition_variable>
#include <optional>

template <typename T>
class NonblockingMutexQueue
{
private:
    std::queue<T> queue_;
    std::mutex mutex_;

public:
    void push(const T &value)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        queue_.push(value);
    }

    std::optional<T> pop()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        if (queue_.empty())
            return std::nullopt;
        T value = queue_.front();
        queue_.pop();
        return value;
    }

    bool empty()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return queue_.empty();
    }
};

#endif