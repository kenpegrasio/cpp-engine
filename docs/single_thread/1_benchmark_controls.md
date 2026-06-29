# Benchmark Controls

Before analyzing latency and throughput, we need a reliable benchmarking methodology. Since low-level performance measurements are sensitive to noise from the operating system, CPU scheduling, frequency scaling, and background processes, I apply the following benchmark controls to make the results more stable and reproducible.

The given `bench_controls/check_controls.sh` will help checking all these conditions before starting benchmark. 

## CPU Frequency Scaling Governor

The first benchmark control is the CPU Frequenc Scaling Governer. Linux has the CPU Frequency Scaling feature that can enable the OS to scale the CPU frequency up and down. We are particularly interested in the governor. 

There are a lot of governors' type, more can be found on this [wiki](https://wiki.archlinux.org/title/CPU_frequency_scaling#Scaling_governors). Our choice on the governers will affect how the OS will sale the CPU frequency. Instead of having the frequency be adjusted dynamically, we will keep the CPU at the maximum frequency when performing the benchmark, which is `performance` governor. 

In **Linux**, to check the current governor for each CPU core, you can run the following command:

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

To adjust the governor to performance mode, you can run the following command:

```bash
sudo cpupower frequency-set -g performance
```

In **Windows**, you can check the power scheme using the following command:

```bash
powercfg /getactivescheme
```

You can list the available plans using `powercfg /list` and set high performance, for example, using the following command:

```bash
powercfg /setactive SCHEME_MIN
```

## Frequency Boosting

Next, some processors also support raising the frequency to be above normal maximum for a short while; this feature is called Intel Turbo Boost or AMD Turbo-Core. This feature may create variances during our benchmarking. 

To turn off frequency boosting, you need to write `1` into `/sys/devices/system/cpu/intel_pstate/no_turbo`. You can do this by running the following command:

```bash
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

In Windows, you can check the current active power plan using the following command:

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

## Process Pinning

Inside the operating system scheduler, the kernel may also perform processes migration from one core to another, i.e., load balancing. When this happen during benchmarking, this may introduce unwanted variances. 

Therefore, to avoid this, the all scripts related to benchmarking will pin the process to a specific core using the `taskset -c "$CPU_ID"` command. 

## Other Setup 

Computer has different scheme when it is plugged in or on battery. A practical example of this is that your computer will be on power saving mode when your battery is low. To avoid this, especially knowing that it may change the CPU frequency as mentioned earlier, the computer need to be **plugged in** during the benchmarking process. 

Other than this, other applications that currently running will need to be shut down during the benchmarking process. Throughout the benchmarking process, only open terminal that run the benchmarking script. This is to minimize and eliminate background processes noise.
