CXX = g++
COMMON_FLAGS = -std=c++20 -Iinclude
RELEASE_FLAGS = -O2 -g
DEBUG_FLAGS = -O1 -g -fno-omit-frame-pointer
ASAN_UBSAN_FLAGS = $(DEBUG_FLAGS) -fsanitize=address,undefined
TSAN_FLAGS = $(DEBUG_FLAGS) -fsanitize=thread

all: engine_v1 engine_v2 engine_v3 check

check: checker/checker.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $< -o $@

engine_v1: src/engine_v1.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $< -o $@

engine_v2: src/engine_v2.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $< -o $@

engine_v3: src/engine_v3.cpp
	$(CXX) $(COMMON_FLAGS) $(RELEASE_FLAGS) $< -o $@

sanitize: engine_v1_asan engine_v2_asan engine_v3_asan

thread-sanitize: engine_v1_tsan engine_v2_tsan engine_v3_tsan

engine_v1_asan: src/engine_v1.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) $< -o $@

engine_v2_asan: src/engine_v2.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) $< -o $@

engine_v3_asan: src/engine_v3.cpp
	$(CXX) $(COMMON_FLAGS) $(ASAN_UBSAN_FLAGS) $< -o $@

engine_v1_tsan: src/engine_v1.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) $< -o $@

engine_v2_tsan: src/engine_v2.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) $< -o $@

engine_v3_tsan: src/engine_v3.cpp
	$(CXX) $(COMMON_FLAGS) $(TSAN_FLAGS) $< -o $@

clean:
	rm -f engine_v1 engine_v2 engine_v3 check
	rm -f engine_v1_asan engine_v2_asan engine_v3_asan
	rm -f engine_v1_tsan engine_v2_tsan engine_v3_tsan

.PHONY: all sanitize thread-sanitize clean
