#!/usr/bin/env bash
# Patch generic-Linux ELFs inside Pants' append-only named caches so they
# exec Nix-native (no FHS sandbox): executables get their interpreter
# rewritten, and wheel-provided shared objects (greenlet, psycopg, ...)
# get an rpath so their libstdc++/libgcc DT_NEEDED entries resolve.
# Idempotent, stamp-guarded, single-flight; the pants wrapper invokes it
# synchronously (PANTS_NIX_AUTOPATCH=0 disables).
#
# Substituted at build time by substituteAll: @nixInterpreter@ / @nixRpath@.
set -uo pipefail

for tool in patchelf ldd flock; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "pants-patch-caches: $tool not found on PATH — rerun through the pants wrapper or install it" >&2
    exit 1
  }
done

CACHE="${PANTS_HOME:-$HOME/.cache/pants}/named_caches"
# scie-pants' interpreter cache (python-build-standalone trees) is used
# by PEX venvs created under the official launcher — patch it too.
NCE_CACHE="$HOME/.cache/nce"
STAMP="$CACHE/.nix-patched"

if [ ! -d "$CACHE" ] && [ ! -d "$NCE_CACHE" ]; then
  exit 0
fi

# Single-flight: concurrent Pants launches must not sweep the same
# binaries at once (the per-file temp names would interleave). Skipping
# is safe — the in-flight sweep sees at least as much. The lock lives
# OUTSIDE the scanned caches: recreating it inside would bump its ctime
# above the stamp and defeat the fast path forever.
PANTS_CACHE_ROOT="${PANTS_HOME:-$HOME/.cache/pants}"
mkdir -p "$PANTS_CACHE_ROOT" 2>/dev/null || true
exec 9>"$PANTS_CACHE_ROOT/.nix-sweep.lock"
flock -n 9 || exit 0

# Fast path: nothing changed under either cache since the last sweep.
# Compare ctime against ctime (-newercc): unpacked archives keep their
# original mtimes, so mtime comparisons would miss freshly extracted
# trees; -cnewer would compare against the stamp's mtime and match the
# stamp itself.
if [ -e "$STAMP" ]; then
  if ! find "$CACHE" "$NCE_CACHE" -type f -newercc "$STAMP" -print -quit 2>/dev/null | grep -q .; then
    exit 0
  fi
fi

# Stamp the sweep start, commit it only at the end: files created while
# the sweep runs stay newer than the stamp and are picked up next time
# (an end-of-run stamp would silently skip them forever). Costs one
# cheap no-op re-sweep after every productive sweep.
STAMP_NEW="$STAMP.tmp"
touch "$STAMP_NEW" 2>/dev/null || STAMP_NEW=""

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
done < <(
  if [ -e "$STAMP" ]; then
    find "$CACHE" "$NCE_CACHE" -type f -perm /111 -newercc "$STAMP" -print0 2>/dev/null
  else
    find "$CACHE" "$NCE_CACHE" -type f -perm /111 -print0 2>/dev/null
  fi
)

# Shared objects: patch ONLY those with unresolvable DT_NEEDED entries
# (e.g. greenlet needing libstdc++). Blanket rpath-rewrites corrupted
# large mypyc/Cython modules (black) — patchelf's in-place rewrite is
# not safe for every ELF, so never touch healthy objects. The rpath is
# appended (--add-rpath): replacing it here would drop the auditwheel
# $ORIGIN/../... entries of exactly the mixed objects that pass the
# ldd gate.
sos=0
while IFS= read -r -d '' so; do
  ldd "$so" 2>/dev/null | command grep -q 'not found' || continue
  old_rpath=$(patchelf --print-rpath "$so" 2>/dev/null) || continue
  case "$old_rpath" in
    *@nixRpath@*) continue ;;    # already patched; remaining needs won't resolve here
  esac
  tmp="$so.nixtmp"
  if cp --reflink=auto "$so" "$tmp" 2>/dev/null \
     && patchelf --add-rpath @nixRpath@ "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$so"; then
    sos=$((sos + 1))
  else
    rm -f "$tmp"
  fi
done < <(
  if [ -e "$STAMP" ]; then
    find "$CACHE" "$NCE_CACHE" -type f \( -name '*.so' -o -name '*.so.*' \) -newercc "$STAMP" -print0 2>/dev/null
  else
    find "$CACHE" "$NCE_CACHE" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null
  fi
)

if [ -n "$STAMP_NEW" ]; then
  mv -f "$STAMP_NEW" "$STAMP"
fi
echo "pants-patch-caches: patched $patched binaries, $sos shared objects" >&2
exit 0
