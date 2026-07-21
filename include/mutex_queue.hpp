#ifndef MUTEX_QUEUE_HPP
#define MUTEX_QUEUE_HPP

#include <queue>
#include <mutex>
#include <condition_variable>
#include <optional>

template <typename T>
class MutexQueue
{
private:
    std::queue<T> queue_;
    std::mutex mutex_;
    std::condition_variable cond_var_;
    bool closed_ = false;

public:
    void push(const T &value)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.push(value);
        }
        cond_var_.notify_one();
    }

    std::optional<T> pop()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        cond_var_.wait(lock, [&]
                       { return !queue_.empty() || closed_; });
        if (closed_ && queue_.empty())
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

    void close()
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            closed_ = true;
        }
        cond_var_.notify_all();
    }
};

#endif