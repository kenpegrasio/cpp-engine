// Usage: checker <binary_a> <binary_b> [input_files_or_dirs...]
// If no inputs are given, defaults to tests/generated/*.txt relative to cwd.

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static int run_engine(const fs::path& engine, const fs::path& input, const fs::path& output) {
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }
    if (pid == 0) {
        int in_fd   = open(input.c_str(),  O_RDONLY);
        int out_fd  = open(output.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        int null_fd = open("/dev/null",    O_WRONLY);

        if (in_fd < 0 || out_fd < 0) _exit(127);

        dup2(in_fd,   STDIN_FILENO);
        dup2(out_fd,  STDOUT_FILENO);
        if (null_fd >= 0) dup2(null_fd, STDERR_FILENO);

        close(in_fd); close(out_fd);
        if (null_fd >= 0) close(null_fd);

        execl(engine.c_str(), engine.c_str(), nullptr);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

struct Mismatch {
    int line_no;
    std::string a_line, b_line;
    bool a_eof, b_eof;
};

static std::vector<Mismatch> collect_diffs(const fs::path& a_path, const fs::path& b_path,
                                            int max_diffs = 10) {
    std::ifstream a(a_path), b(b_path);
    std::string a_line, b_line;
    int line_no = 1;
    std::vector<Mismatch> diffs;

    while ((int)diffs.size() < max_diffs) {
        bool a_ok = static_cast<bool>(std::getline(a, a_line));
        bool b_ok = static_cast<bool>(std::getline(b, b_line));

        if (!a_ok && !b_ok) break;

        if (a_ok != b_ok || a_line != b_line)
            diffs.push_back({line_no, a_ok ? a_line : "", b_ok ? b_line : "", !a_ok, !b_ok});

        ++line_no;
    }
    return diffs;
}

static bool check_one(const fs::path& engine_a, const fs::path& engine_b, const fs::path& input) {
    const fs::path tmp   = fs::temp_directory_path();
    const fs::path out_a = tmp / "checker_a.out";
    const fs::path out_b = tmp / "checker_b.out";

    int code_a = run_engine(engine_a, input, out_a);
    int code_b = run_engine(engine_b, input, out_b);

    if (code_a != 0 || code_b != 0) {
        std::cout << "[FAIL] " << input.string() << "\n"
                  << "  " << engine_a.filename().string() << " exit code: " << code_a << "\n"
                  << "  " << engine_b.filename().string() << " exit code: " << code_b << "\n";
        return false;
    }

    const auto diffs = collect_diffs(out_a, out_b);
    if (diffs.empty()) {
        std::cout << "[PASS] " << input.string() << "\n";
        return true;
    }

    std::cout << "[FAIL] " << input.string()
              << " (" << diffs.size() << "+ differing line(s))\n";
    for (const auto& d : diffs) {
        std::cout << "  line " << d.line_no << ":\n"
                  << "    " << engine_a.filename().string() << ": "
                  << (d.a_eof ? "<EOF>" : d.a_line) << "\n"
                  << "    " << engine_b.filename().string() << ": "
                  << (d.b_eof ? "<EOF>" : d.b_line) << "\n";
    }
    return false;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr << "usage: checker <binary_a> <binary_b> [input_files_or_dirs...]\n";
        return 2;
    }

    // Use absolute paths so execl works correctly regardless of cwd after fork.
    const fs::path engine_a = fs::absolute(argv[1]);
    const fs::path engine_b = fs::absolute(argv[2]);

    if (!fs::exists(engine_a)) { std::cerr << "not found: " << engine_a << "\n"; return 2; }
    if (!fs::exists(engine_b)) { std::cerr << "not found: " << engine_b << "\n"; return 2; }

    std::vector<fs::path> inputs;

    auto collect_dir = [&](const fs::path& dir) {
        for (const auto& entry : fs::directory_iterator(dir))
            if (entry.path().extension() == ".txt")
                inputs.push_back(entry.path());
    };

    if (argc > 3) {
        for (int i = 3; i < argc; ++i) {
            fs::path p = argv[i];
            if (fs::is_directory(p)) collect_dir(p);
            else                     inputs.push_back(p);
        }
    } else {
        const fs::path default_dir = "tests/generated";
        if (fs::is_directory(default_dir))
            collect_dir(default_dir);
    }

    std::sort(inputs.begin(), inputs.end());

    if (inputs.empty()) {
        std::cerr << "no input files found\n";
        return 2;
    }

    bool all_passed = true;
    for (const auto& input : inputs) {
        if (!fs::exists(input)) {
            std::cout << "[FAIL] missing: " << input.string() << "\n";
            all_passed = false;
            continue;
        }
        all_passed = check_one(engine_a, engine_b, input) && all_passed;
    }

    return all_passed ? 0 : 1;
}
