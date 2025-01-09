#!/bin/bash

set -xe
declare -a kvs_lens=("10" "50" "100" "200" "400" "800")
# declare -a kvs_lens=("10")
for kvs_len in "${kvs_lens[@]}"; do
  zig build -Doptimize=ReleaseFast -Dkvs_len=$kvs_len -Dmax_len=16 -Dmin_len=1 -Dnum_iters=10000 -Dwordlist_path=/usr/share/dict/american-english
  # zig build -Doptimize=ReleaseFast -Dkvs_len=$kvs_len -Dmax_len=16 -Dmin_len=1 -Dnum_iters=1000
  # ../poop/zig-out/bin/poop -d 2000 'zig-out/bin/bench std_static_map' 'zig-out/bin/bench hamt'
  ../poop/zig-out/bin/poop -d 2000 'zig-out/bin/bench std_string_hashmap_runtime_init' 'zig-out/bin/bench hamt_runtime_init'
done
