#!/usr/bin/env bash
# List stable Pants releases (in the supported range) with their x86_64
# and aarch64 manylinux wheel asset names, one
# "release_<tag> <x86_64-wheel> <aarch64-wheel>" line per version.
# Output feeds scripts/gen-versions.sh.
#
# Pages until exhausted — a fixed page count silently drops releases as
# the history grows — and enforces the supported floor (>= 2.21.0).
set -euo pipefail
page=1
while :; do
  resp=$(curl -sf "https://api.github.com/repos/pantsbuild/pants/releases?per_page=100&page=$page")
  count=$(jq 'length' <<<"$resp")
  jq -r '
    .[] | select(.prerelease == false)
        | select(.tag_name | test("^release_[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | (.tag_name | ltrimstr("release_") | split(".") | map(tonumber)) as $v
        | select($v[0] > 2 or ($v[0] == 2 and $v[1] > 21) or ($v[0] == 2 and $v[1] == 21))
        | .tag_name as $t
        | ([.assets[].name | select(test("pantsbuild[._]pants-.*manylinux.*x86_64\\.whl"))] | first) as $x
        | ([.assets[].name | select(test("pantsbuild[._]pants-.*manylinux.*aarch64\\.whl"))] | first) as $a
        | select($x != null and $a != null)
        | "\($t) \($x) \($a)"
  ' <<<"$resp"
  [ "$count" -lt 100 ] && break
  page=$((page + 1))
  sleep 0.5
done | sort -V
