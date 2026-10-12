#!/usr/bin/env bash
# List stable Pants releases (in the supported range) with their x86_64
# manylinux wheel asset names, one "release_<tag> <wheel>" line per
# version. Output feeds scripts/gen-versions.sh.
set -euo pipefail
for p in 1 2 3; do
  curl -sf "https://api.github.com/repos/pantsbuild/pants/releases?per_page=100&page=$p"
  sleep 0.5
done | jq -r '
  .[] | select(.prerelease == false)
      | select(.tag_name | test("^release_[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | .tag_name as $t
      | ([.assets[].name | select(test("pantsbuild[._]pants-.*manylinux.*x86_64\\.whl"))] | first) as $w
      | select($w != null)
      | "\($t) \($w)"
' | sort -V
