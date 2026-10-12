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
# scie-pants' interpreter cache (python-build-standalone trees) is used
# by PEX venvs created under the official launcher — patch it too.
NCE_CACHE="$HOME/.cache/nce"
STAMP="$CACHE/.nix-patched"

if [ ! -d "$CACHE" ] && [ ! -d "$NCE_CACHE" ]; then
  exit 0
fi

# Fast path: nothing changed under either cache since the last sweep.
if [ -e "$STAMP" ]; then
  if ! find "$CACHE" "$NCE_CACHE" -type f -newer "$STAMP" -print -quit 2>/dev/null | grep -q .; then
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
  # Append the Nix lib dir to the existing rpath — replacing it would
  # break self-contained trees that carry their own libs (e.g.
  # python-build-standalone's $ORIGIN/../lib).
  old_rpath=$(patchelf --print-rpath "$bin" 2>/dev/null || true)
  new_rpath="@nixRpath@"
  case "$old_rpath" in
    @nixRpath@*) ;;
    "") ;;
    *) new_rpath="$old_rpath:@nixRpath@" ;;
  esac
  tmp="$bin.nixtmp"
  if cp --reflink=auto "$bin" "$tmp" 2>/dev/null \
     && patchelf --set-interpreter @nixInterpreter@ --set-rpath "$new_rpath" "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$bin"; then
    patched=$((patched + 1))
  else
    rm -f "$tmp"
  fi
done < <(find "$CACHE" "$NCE_CACHE" -type f -perm /111 -print0 2>/dev/null)

# Shared objects: patch ONLY those with unresolvable DT_NEEDED entries
# (e.g. greenlet needing libstdc++). Blanket rpath-rewrites corrupted
# large mypyc/Cython modules (black) — patchelf's in-place rewrite is
# not safe for every ELF, so never touch healthy objects.
sos=0
while IFS= read -r -d '' so; do
  ldd "$so" 2>/dev/null | command grep -q 'not found' || continue
  tmp="$so.nixtmp"
  if cp --reflink=auto "$so" "$tmp" 2>/dev/null \
     && patchelf --set-rpath @nixRpath@ "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$so"; then
    sos=$((sos + 1))
  else
    rm -f "$tmp"
  fi
done < <(
  if [ -e "$STAMP" ]; then
    find "$CACHE" "$NCE_CACHE" -type f \( -name '*.so' -o -name '*.so.*' \) -newer "$STAMP" -print0 2>/dev/null
  else
    find "$CACHE" "$NCE_CACHE" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null
  fi
)

touch "$STAMP"
echo "pants-patch-caches: patched $patched binaries, $sos shared objects" >&2
exit 0
