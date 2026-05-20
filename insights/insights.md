# Insights

## No matching order

### Maximum latency

An important note in analyzing the maximum latency is that: since we only take one single sample, the maximum latency can be influenced by a lot of OS noises, such as process scheduling, pre-emption, etc. 

In cases of no matching order, such as all buy, all sell, or mix unmatched, the hypothesis is that this latency is come from the vector memory re-allocation. 

The maximum latency for `v2` skyrocketed. This is most likely because the priority queue size explode. Each priority queue entry consists of 24 bytes; compared to `v1`, which only save pointers (8 byte). So, reallocation becomes very expensive. 

The engine v3 implementation does not suffer from this because:

1. Data is splitted across price through the map
2. Deque internal managed the data through chunks. Re-allocation only happens in terms of chunks, not individual data like in engine v1 and v2. 

It is also important to note that the probability of encountering memory re-allocation is only $O(\log N)$, which only sits at the top 20 when $N=100000$; top 20 is `p99.998`.  

### `p50`, `p95` and `p99` latency

The engine v3 latency loses against engine v1 and v2 in this cases because of several reasons:

#### Repeated random insertion 

According to the `Repeated Random Insertion into a Priority Queue` paper, the average number of bubble up need to be done for repeated random insertion (from `n!` permutations of `n` distinct numbers) is $1.7645$. It is bounded, and not $\log N$. 

#### Pointer indirection

The underlying implementation of deque uses chunks instead of direct value representation. Therefore, there are an additional of pointer indirection introduced. 

Additionally, the map is implemented using red-black tree underneath the hood, which is less cache-friendly compared to priority queue (uses vector). 

## Matching orders

### Heavy overlap 

In heavy overlap, the matching logic complexity started to play a role. As the number of matches occur in one iteration increases, the latency will be affected. 

The complexity analysis of each engine is as follows:

| Engine | Single matching logic complexity | Number of bytes for comparison |
|---:|---|---|
| `v1` | $1 \times O(\log N)$ on partial match, $2 \times O(\log N)$ on exact match | 8, `sizeof(Order*)` | 
| `v2` | $3 \times O(\log N)$ on partial match, $2 \times O(\log N)$ on exact match | 24, `sizeof(Order)` | 
| `v3` | $O(1)$ for `rbegin` or `begin` access + $O(1)$ amortized for deque operation + $O(1)$ amortized for erase using iterator | 8, `sizeof(unsigned long long)` | 

The $3 \times O(\log N) $ cannot be optimized, as priority queue does not allow changing top value directly (it returns `const Order`). 

From the matching logic complexity, complexity of `v3` < complexity of `v1` < complexity of `v2`. This will start to dominate as we move on from p50 to p95 to p99. 

### Wide range 

In wide range, the number of orders in the queue should be more than in heavy overlap. As a consequence, this result in the latency for engine v1 and v2 to increase as they depend on $O(\log N)$.

Compared to engine v3, it only requires $O(1)$ amortized. Therefore, the gap between the latency of engine v1 and v2 compared to v3 becomes larger. 