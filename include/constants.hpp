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

#endif