# Benchmark Controls in Single-Threaded Matching Engine

## CPU Frequency Scaling Governor

Linux has the CPU Frequency Scaling feature that can enable the OS to scale the CPU frequency up and down. In this section, we are particularly interested in the governor. 

There are a lot of governors' type, more can be found on this [wiki](https://wiki.archlinux.org/title/CPU_frequency_scaling#Scaling_governors). Instead of having the frequency be adjusted dynamically, we will keep the CPU at the maximum frequency when performing the benchmark, which is `performance` governor. 

To check the current governor for each CPU core, you can run the following command:

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

To adjust the governor to performance mode, you can run the following command:

```bash
sudo cpupower frequency-set -g performance
```

On the other hand, you can check the power scheme on Windows using the following command:

```bash
powercfg /getactivescheme
```

You can list the available plans using `powercfg /list` and set high performance, for example, using the following command:

```bash
powercfg /setactive SCHEME_MIN
```

## Frequency Boosting

Some processors support raising the frequency to be above normal maximum for a short while; this feature is called Intel Turbo Boost or AMD Turbo-Core. This feature may create variances during our benchmarking. 

To turn off frequency boosting, you need to write `1` into `/sys/devices/system/cpu/intel_pstate/no_turbo`. You can do this by running the following command:

```bash
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

In Windows, on the other hand, you can check the current active power plan using the following command:

```bash
powercfg /getactivescheme
```

Then, to turn off the frequency boosting, you need to run the following commands:

```bash
# Disable processor boost/turbo when plugged in
powercfg /setacvalueindex scheme_current sub_processor PERFBOOSTMODE 0

# Also disable boost on battery
powercfg /setdcvalueindex scheme_current sub_processor PERFBOOSTMODE 0

# Apply the updated plan
powercfg /setactive scheme_current
```

## Kernel-level Load Balancing

Inside the operating system scheduler, the kernel may perform processes migration from one core to another. When this happen during benchmarking, this may introduce unwanted variances. 

Therefore, to avoid this the `sweep.sh` script will pin the process to a specific core using the `taskset -c "$CPU_ID"` command. 

## Computer Setup 

Computer has different scheme when it is plugged in or on battery. A practical example of this is that your computer will be on power saving mode when your battery is low. To avoid this, especially knowing that it may change the CPU frequency as mentioned earlier, the computer is set to be **plugged in** during the benchmarking process. 

Other than this, other applications that currently running will need to be shut down during the benchmarking process. If possible, open only the terminal that run the benchmarking script throughout the benchmarking process. 
