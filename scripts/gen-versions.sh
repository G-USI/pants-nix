#!/usr/bin/env bash
# Generate per-version packaging data for every stable Pants release in
# the supported range. Parsing/resolution lives in scripts/generate.py,
# run under nix-backed Python (the host python is not usable on NixOS).
#
# Usage: gen-versions.sh <tag-file>
# where <tag-file> holds "release_<tag> <wheel-filename>" lines from
# scripts/list-versions.sh.
set -euo pipefail
IN="${1:?usage: gen-versions.sh <tag-file>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec nix shell nixpkgs#python3 --command python3 "$ROOT/scripts/generate.py" "$IN" "$ROOT"
