#ifndef CONSTANTS_HPP
#define CONSTANTS_HPP

/*
    This constant need to be changed if the number of physical cores is changed. This is used for pinning threads to cores in benchmark mode.
    To check how many physical cores you have, you need to run the following commnd:
        for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "$(basename $c): $(cat $c/topology/thread_siblings_list)"; done
    And also to find which cores is the P-core, you can run the following command:
        cat /sys/devices/cpu_core/cpus
    Count how the number of distinct pairs in the output of the first command, and find which cores are listed in the second command.
    Those cores are the P-cores. We will not use the E-cores for pinning threads in benchmark mode, as they are not as performant as the P-cores.
    Source: https://www.supermicro.com/en/glossary/e-cores-p-cores
*/

const int NUMBER_OF_PHYSICAL_P_CORES = 6;
const int MAX_PRICE = 200;
// Compile-time cap on shards/instruments. Sizes std::array members in EngineV6A/_NB/V6B
// (books, queues, per-book mutexes), so raising it costs memory whether or not the
// shards are used: 16 books x sizeof(EngineV5S)=32KB ~ 504KB, and those engines are
// STACK locals in the runners' main() (8MB default stack: 64 is fine at ~2MB,
// 128 would be ~4MB, 256 would overflow).
//
// 64 exists for the Design A (V6B) scaling study: per-book locking is contention-bound
// when threads outnumber books -- with T threads over B books the expected number of
// distinct books in play is B*(1-(1-1/B)^T), so 4 threads over 4 books reach only 68%
// parallel efficiency, while 4 over 64 reach 98%.
// Testing V6B at B=3 measures its worst case, not its design point.
const int MAX_SHARDS = 64;

#endif