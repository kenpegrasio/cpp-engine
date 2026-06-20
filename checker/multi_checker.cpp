// Usage: multi_checker <engine> <input_file> [extra engine args...]
//
// Runs `<engine> < <input_file>` (engine_v4 in LOG mode, i.e. WITHOUT
// --benchmark), captures the engine's stdout, and parses it back into a
// std::vector<Log>. The correctness replay over that log is left as a TODO at
// the bottom of main() — `logs` is ready for you there.
//
// Extra args after the input file are forwarded to the engine verbatim, e.g.
//   ./multi_check ./engine_v4 tests/generated/foo.txt --N 8
// (Do NOT pass --benchmark: that makes the engine print stats instead of logs.)

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <filesystem>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>
#include <set>

#include "types.hpp"
#include "engines.hpp"
#include "constants.hpp"
#include "parser.hpp"
#include "utils.hpp"

namespace fs = std::filesystem;

// ── Run the engine with stdin <- input file, capture its stdout as a string ──
// stderr is redirected to /dev/null so engine warnings (e.g. the --N notices)
// never mix into the parsed stream. We drain the pipe to EOF *before* reaping
// the child, so a large log can't deadlock on a full pipe buffer.
static std::string run_and_capture(const std::string &engine,
                                   const std::string &input,
                                   const std::vector<std::string> &extra_args,
                                   int &exit_code)
{
    int pipefd[2];
    if (pipe(pipefd) != 0)
    {
        perror("pipe");
        exit_code = -1;
        return {};
    }

    pid_t pid = fork();
    if (pid < 0)
    {
        perror("fork");
        close(pipefd[0]);
        close(pipefd[1]);
        exit_code = -1;
        return {};
    }

    if (pid == 0)
    {
        // ── child: wire stdin <- input, stdout -> pipe, stderr -> /dev/null ──
        int in_fd = open(input.c_str(), O_RDONLY);
        int null_fd = open("/dev/null", O_WRONLY);
        if (in_fd < 0)
            _exit(127);

        dup2(in_fd, STDIN_FILENO);
        dup2(pipefd[1], STDOUT_FILENO);
        if (null_fd >= 0)
            dup2(null_fd, STDERR_FILENO);

        close(pipefd[0]);
        close(pipefd[1]);
        close(in_fd);
        if (null_fd >= 0)
            close(null_fd);

        // argv = { engine, extra_args..., nullptr }
        std::vector<char *> child_argv;
        child_argv.push_back(const_cast<char *>(engine.c_str()));
        for (const auto &a : extra_args)
            child_argv.push_back(const_cast<char *>(a.c_str()));
        child_argv.push_back(nullptr);

        execv(engine.c_str(), child_argv.data());
        _exit(127); // exec failed
    }

    // ── parent: read child's stdout to EOF, THEN reap ───────────────────────
    close(pipefd[1]); // we only read

    std::string out;
    char buf[1 << 16];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0)
        out.append(buf, static_cast<std::size_t>(n));
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return out;
}

// ── Parse the engine's log output back into std::vector<Log> ────────────────
// Format (non-benchmark mode) produced by engine_v4:
//   <number_of_logs>
//   Receive <order_id> <B|S> <count> <price>
//   Match   <count> <buy_order_id> <sell_order_id>
//   ...
// Token-based (operator>>), so it is insensitive to exact spacing/newlines.
static std::vector<Log> parseLogs(const std::string &text)
{
    std::istringstream in(text);

    std::size_t count = 0;
    in >> count; // leading log count — used only to reserve

    std::vector<Log> logs;
    logs.reserve(count);

    std::string tag;
    while (in >> tag)
    {
        if (tag == "Receive")
        {
            int order_id;
            char side;
            unsigned int qty;
            unsigned long long price;
            in >> order_id >> side >> qty >> price;
            const OrderSide os = (side == 'B') ? OrderSide::Buy : OrderSide::Sell;
            logs.push_back(Log(LogType::Receive, Order(order_id, os, qty, price)));
        }
        else if (tag == "Match")
        {
            int qty, buy_id, sell_id;
            in >> qty >> buy_id >> sell_id;
            // Transaction(buy_order_id, sell_order_id, count)
            logs.push_back(Log(LogType::Match, Transaction(buy_id, sell_id, qty)));
        }
        else
        {
            std::cerr << "[warn] unexpected token in engine output: '" << tag << "'\n";
        }
    }
    return logs;
}

int main(int argc, char **argv)
{
    if (argc < 3)
    {
        std::cerr << "usage: " << argv[0]
                  << " <engine> <input_file> [extra engine args...]\n"
                  << "  runs `<engine> < <input_file>` in log mode (no --benchmark)\n";
        return 2;
    }

    // Absolute paths so exec/open are robust regardless of cwd (mirrors single_checker).
    const std::string engine = fs::absolute(argv[1]).string();
    const std::string input = fs::absolute(argv[2]).string();

    if (!fs::exists(engine))
    {
        std::cerr << "not found: " << engine << "\n";
        return 2;
    }
    if (!fs::exists(input))
    {
        std::cerr << "not found: " << input << "\n";
        return 2;
    }

    std::vector<std::string> extra_args;
    for (int i = 3; i < argc; ++i)
        extra_args.emplace_back(argv[i]);

    int exit_code = 0;
    const std::string output = run_and_capture(engine, input, extra_args, exit_code);
    if (exit_code != 0)
    {
        std::cerr << "[error] engine exited with code " << exit_code << "\n";
        return 1;
    }
    std::vector<Log> logs = parseLogs(output);
    std::cerr << "[info] parsed " << logs.size() << " log entries\n";

    // ────────────────────────────────────────────────────────────────────────
    // Sequentiality receive order check per thread. Match can be mixed up, but receive order should be sequential per thread.
    // This is a sanity check to ensure that the engine is not reordering receive orders from the same thread
    // ────────────────────────────────────────────────────────────────────────

    int N = NUMBER_OF_PHYSICAL_P_CORES;
    for (size_t i = 0; i < extra_args.size(); ++i)
    {
        if (extra_args[i] == "--N" && i + 1 < extra_args.size())
        {
            N = std::stoi(extra_args[i + 1]);
            break;
        }
    }

    std::ifstream input_file(input);
    if (!input_file)
    {
        std::cerr << "[error] failed to open input file: " << input << "\n";
        return 1;
    }

    std::vector<Order> orders = parseOrders(input_file);
    std::vector<std::vector<Order>> split_orders = splitOrders(orders, N);
    std::vector<int> ptrs;
    std::map<int, int> order_id_to_thread_map;
    for (int i = 0; i < N; i++)
    {
        // assume that each thread has at least one order to process
        if (split_orders[i].empty())
        {
            std::cerr << "[error] thread " << i << " has no orders to process\n";
            return 1;
        }
        ptrs.push_back(0);
    }

    std::set<int> current_order_ids;
    for (int i = 0; i < N; i++)
    {
        current_order_ids.insert(split_orders[i][0].order_id);
        ptrs[i]++;
        order_id_to_thread_map[split_orders[i][0].order_id] = i;
    }

    for (auto &log : logs)
    {
        if (log.log_type == LogType::Receive)
        {
            if (current_order_ids.find(log.order.order_id) == current_order_ids.end())
            {
                std::cerr << "[error] receive order out of sequence: order_id=" << log.order.order_id << "\n";
                return 1;
            }
            current_order_ids.erase(log.order.order_id);
            int thread_id = order_id_to_thread_map[log.order.order_id];
            order_id_to_thread_map.erase(log.order.order_id);
            if (ptrs[thread_id] < split_orders[thread_id].size())
            {
                current_order_ids.insert(split_orders[thread_id][ptrs[thread_id]].order_id);
                order_id_to_thread_map[split_orders[thread_id][ptrs[thread_id]].order_id] = thread_id;
                ptrs[thread_id]++;
            }
        }
    }

    for (int i = 0; i < N; i++)
    {
        if (ptrs[i] != split_orders[i].size())
        {
            std::cerr << "[error] not all orders from thread " << i << " were received\n";
            return 1;
        }
    }

    std::cout << "Success: all receive orders are in sequence per thread.\n";

    // ────────────────────────────────────────────────────────────────────────
    // Replay `logs` through the single-threaded matching logic and
    // verify that the concurrent reordering never changed which orders matched
    // (i.e. no later-arriving order illegitimately bypassed an order it should
    // have crossed). `logs` is fully populated and ready to consume here.
    // ────────────────────────────────────────────────────────────────────────

    EngineV3 engine_v3;
    std::vector<Transaction> cur_transactions;
    for (auto &log : logs)
    {
        if (log.log_type == LogType::Receive)
        {
            engine_v3.receive(log.order);
            auto transactions_span = engine_v3.match();
            if (transactions_span.empty())
            {
                continue;
            }
            if (!transactions_span.empty() && !cur_transactions.empty())
            {
                std::cerr << "[error] unexpected Match log with non-empty cur_transactions\n";
                return 1;
            }
            cur_transactions = std::vector<Transaction>(transactions_span.begin(), transactions_span.end());
            std::reverse(cur_transactions.begin(), cur_transactions.end());
        }
        else
        {
            if (cur_transactions.empty())
            {
                std::cerr << "[error] unexpected Match log with no transactions\n";
                return 1;
            }
            const Transaction expected = cur_transactions.back();
            cur_transactions.pop_back();
            const Transaction actual = log.transaction;
            if (expected.buy_order_id != actual.buy_order_id ||
                expected.sell_order_id != actual.sell_order_id ||
                expected.count != actual.count)
            {
                std::cerr << "[error] transaction mismatch:\n"
                          << "  expected: buy=" << expected.buy_order_id
                          << " sell=" << expected.sell_order_id
                          << " count=" << expected.count << "\n"
                          << "  actual:   buy=" << actual.buy_order_id
                          << " sell=" << actual.sell_order_id
                          << " count=" << actual.count << "\n";
                return 1;
            }
        }
    }
    if (!cur_transactions.empty())
    {
        std::cerr << "[error] unmatched transactions remain after log replay\n";
        return 1;
    }
    std::cout << "Success: all logs replayed correctly, no transaction mismatches found.\n";
    std::cout << "All checks passed.\n";
    return 0;
}
