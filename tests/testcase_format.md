# Testcase Format

For single shard:

```
<number-of-orders>
<order-id> <B|S> <count> <price>
...
```

For multi shard:
```
<number-of-shards>
<shard-code>

<number-of-orders>
<order-id> <shard-code> <B|S> <count> <price>
```