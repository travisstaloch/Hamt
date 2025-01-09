# About

A generic [HAMT](https://en.wikipedia.org/wiki/Hash_array_mapped_trie) implementation in zig.  


* runtime API following `std.ArrayHashMap(K, V)`
  * `get(key)`, `getOrPut(allocator, key)`, `put(allocator, key, value)`, `init(allocator, kvs)`, `initContext(allocator, kvs, ctx)`
  * can use it's Context types such as `std.array_hash_map.StringContext`
  * `AutoHamt(K, V, .{})` which uses `std.array_hash_map.AutoContext(K)`
  * `StringHamt(V, .{})` which uses `std.array_hash_map.StringContext`
* comptime, static API
  * `initComptime(kvs)`, `putComptime(key, value)`

# Notes
Branch nodes use custom ArrayLinkedList to save memory.

# Bench
see [bench.sh](bench.sh) and [src/bench.zig](src/bench.zig)

# Todo
- [ ] support removal
  - [ ] maybe use a free list since ArrayLinkedList ids must be stable.
- [ ] optimize
  - [ ] Hamt.get() vs std.StaticStringMap() - static, with initComptime()
    - timings from `$./bench.sh`
      | Keys | StaticStringMap | Hamt   | % difference |
      | ---  | ---             | ---    | ---          |
      | 10   |  1.38ms         | 2.96ms | +114%        |
      | 50   |  6.56ms         | 16.8ms | +156%        |
      | 100  |  14.8ms         | 35.8ms | +142%        |
      | 200  |  44.8ms         | 77.0ms | +71%         |
      | 400  |  142ms          | 177ms  | +25%         |
      | 800  |  508ms          | 452ms  | -11%         |
  - [ ] combined init() and get() vs std.StringHashMap()
    - timings from `$./bench.sh`
      | Keys | StringHashMap   | Hamt   | % difference |
      | ---  | ---             | ---    | ---          |
      | 10   |  1.93ms         | 2.96ms | +53%         |
      | 50   |  9.66ms         | 16.9ms | +74%         |
      | 100  |  22ms           | 35.9ms | +63%         |
      | 200  |  45.7ms         | 78.0ms | +71%         |
      | 400  |  95ms           | 178ms  | +86%         |
      | 800  |  233ms          | 454ms  | +94%         |

# Other implementations / References
* c - https://github.com/noahbenson/phamt/
* c++ - https://github.com/philsquared/hash_trie/
* zig - https://github.com/paoda/hamt/