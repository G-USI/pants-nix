#!/usr/bin/env bash
# Patch generic-Linux ELFs inside Pants' append-only named caches so they
# exec Nix-native (no FHS sandbox): executables get their interpreter
# rewritten, and wheel-provided shared objects (greenlet, psycopg, ...)
# get an rpath so their libstdc++/libgcc DT_NEEDED entries resolve.
# Idempotent and stamp-guarded; the pants wrapper invokes it
# automatically (PANTS_NIX_AUTOPATCH=0 disables).
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
  tmp="$bin.nixtmp"
  if cp --reflink=auto "$bin" "$tmp" 2>/dev/null \
     && patchelf --set-interpreter @nixInterpreter@ --set-rpath @nixRpath@ "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$bin"; then
    patched=$((patched + 1))
  else
    rm -f "$tmp"
  fi
done < <(find "$CACHE" -type f -perm /111 -print0 2>/dev/null)

# Shared objects: no interpreter to rewrite, but manylinux wheels ship
# them without any rpath — point them at the Nix lib dir so their
# libstdc++/libgcc_s dependencies resolve under Nix interpreters.
# Incremental: after the first full pass, only files newer than the last
# stamp are considered (the cache is append-only, so old entries stay
# patched).
sos=0
while IFS= read -r -d '' so; do
  rpath=$(patchelf --print-rpath "$so" 2>/dev/null) || continue
  case "$rpath" in
    /nix/store/*) continue ;;    # already Nix-rpathed
  esac
  if [ -z "$rpath" ]; then
    tmp="$so.nixtmp"
    if cp --reflink=auto "$so" "$tmp" 2>/dev/null \
       && patchelf --set-rpath @nixRpath@ "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$so"; then
      sos=$((sos + 1))
    else
      rm -f "$tmp"
    fi
  fi
done < <(
  if [ -e "$STAMP" ]; then
    find "$CACHE" -type f \( -name '*.so' -o -name '*.so.*' \) -newer "$STAMP" -print0 2>/dev/null
  else
    find "$CACHE" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null
  fi
)

touch "$STAMP"
echo "pants-patch-caches: patched $patched binaries, $sos shared objects" >&2
exit 0
