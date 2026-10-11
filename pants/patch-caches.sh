#!/usr/bin/env bash
# Patch generic-Linux ELFs inside Pants' append-only named caches so they
# exec Nix-native (no FHS sandbox). Idempotent and stamp-guarded; the
# pants wrapper invokes it automatically (PANTS_NIX_AUTOPATCH=0 disables).
#
# Substituted at build time by substituteAll: @nixInterpreter@ / @nixRpath@.
set -uo pipefail

CACHE="${PANTS_HOME:-$HOME/.cache/pants}/named_caches"
STAMP="$CACHE/.nix-patched"

if [ ! -d "$CACHE" ]; then
  exit 0
fi

# Fast path: nothing changed under the cache since the last sweep.
if [ -e "$STAMP" ]; then
  if ! find "$CACHE" -type f -newer "$STAMP" -print -quit 2>/dev/null | grep -q .; then
    exit 0
  fi
fi

patched=0
while IFS= read -r -d '' bin; do
  interp=$(patchelf --print-interpreter "$bin" 2>/dev/null) || continue
  case "$interp" in
    /nix/store/*) continue ;;    # already Nix-native
    "") continue ;;              # script or ELF without interpreter
  esac
  if patchelf --set-interpreter @nixInterpreter@ \
      --set-rpath @nixRpath@ "$bin" 2>/dev/null; then
    patched=$((patched + 1))
  fi
done < <(find "$CACHE" -type f -perm /111 -print0 2>/dev/null)

touch "$STAMP"
echo "pants-patch-caches: patched $patched binaries" >&2
exit 0
