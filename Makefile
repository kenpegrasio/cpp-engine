CXX = g++
COMMON_FLAGS = -std=c++20 -Iinclude
RELEASE_FLAGS = -O2 -g
DEBUG_FLAGS = -O1 -g -fno-omit-frame-pointer
ASAN_UBSAN_FLAGS = $(DEBUG_FLAGS) -fsanitize=address,undefined
TSAN_FLAGS = $(DEBUG_FLAGS) -fsanitize=thread

ENGINES = engine_v1 engine_v2 engine_v3 engine_v4 engine_v5 engine_v5s \
          engine_v6a engine_v6a_nb engine_v6a_static engine_v6b
CHECKERS = single_check multi_check

ASAN_ENGINES = $(addsuffix _asan,$(ENGINES))
TSAN_ENGINES = $(addsuffix _tsan,$(ENGINES))

all: $(ENGINES) $(CHECKERS)

single_check: checker/single_checker.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $< -o $@

multi_check: checker/multi_checker.cpp src/engine_v3.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $^ -o $@

engine_v1: src/engine_v1_runner.cpp src/engine_v1.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $^ -o $@

engine_v2: src/engine_v2_runner.cpp src/engine_v2.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $^ -o $@

engine_v3: src/engine_v3_runner.cpp src/engine_v3.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $^ -o $@

engine_v4: src/engine_v4_runner.cpp src/engine_v4.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) -pthread $^ -o $@

engine_v5: src/engine_v5_runner.cpp src/engine_v5.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) -pthread $^ -o $@

engine_v5s: src/engine_v5s_runner.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $^ -o $@

engine_v6a: src/engine_v6a_runner.cpp src/engine_v6a.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) -pthread $^ -o $@

engine_v6a_nb: src/engine_v6a_nb_runner.cpp src/engine_v6a_nb.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) -pthread $^ -o $@

engine_v6a_static: src/engine_v6a_runner_static.cpp src/engine_v6a.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) -pthread $^ -o $@

engine_v6b: src/engine_v6b_runner.cpp src/engine_v6b.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) -pthread $^ -o $@

sanitize: $(ASAN_ENGINES)

thread-sanitize: $(TSAN_ENGINES)

engine_v1_asan: src/engine_v1_runner.cpp src/engine_v1.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) $^ -o $@

engine_v2_asan: src/engine_v2_runner.cpp src/engine_v2.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) $^ -o $@

engine_v3_asan: src/engine_v3_runner.cpp src/engine_v3.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) $^ -o $@

engine_v4_asan: src/engine_v4_runner.cpp src/engine_v4.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) -pthread $^ -o $@

engine_v5_asan: src/engine_v5_runner.cpp src/engine_v5.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) -pthread $^ -o $@

engine_v5s_asan: src/engine_v5s_runner.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) $^ -o $@

engine_v6a_asan: src/engine_v6a_runner.cpp src/engine_v6a.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) -pthread $^ -o $@

engine_v6a_nb_asan: src/engine_v6a_nb_runner.cpp src/engine_v6a_nb.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) -pthread $^ -o $@

engine_v6a_static_asan: src/engine_v6a_runner_static.cpp src/engine_v6a.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) -pthread $^ -o $@

engine_v6b_asan: src/engine_v6b_runner.cpp src/engine_v6b.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) -pthread $^ -o $@

engine_v1_tsan: src/engine_v1_runner.cpp src/engine_v1.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) $^ -o $@

engine_v2_tsan: src/engine_v2_runner.cpp src/engine_v2.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) $^ -o $@

engine_v3_tsan: src/engine_v3_runner.cpp src/engine_v3.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) $^ -o $@

engine_v4_tsan: src/engine_v4_runner.cpp src/engine_v4.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) -pthread $^ -o $@

engine_v5_tsan: src/engine_v5_runner.cpp src/engine_v5.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) -pthread $^ -o $@

engine_v5s_tsan: src/engine_v5s_runner.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) $^ -o $@

engine_v6a_tsan: src/engine_v6a_runner.cpp src/engine_v6a.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) -pthread $^ -o $@

engine_v6a_nb_tsan: src/engine_v6a_nb_runner.cpp src/engine_v6a_nb.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) -pthread $^ -o $@

engine_v6a_static_tsan: src/engine_v6a_runner_static.cpp src/engine_v6a.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) -pthread $^ -o $@

engine_v6b_tsan: src/engine_v6b_runner.cpp src/engine_v6b.cpp src/engine_v5s.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) -pthread $^ -o $@

clean:
	rm -f $(ENGINES) $(CHECKERS) $(ASAN_ENGINES) $(TSAN_ENGINES)

.PHONY: all sanitize thread-sanitize clean
