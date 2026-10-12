# Pants, packaged from the official GitHub-release wheel — no FHS.
#
# The native engine (pants/bin/native_client) and native dependency
# extensions are patchelf'd against Nix libraries by autoPatchelfHook.
# Pants runs on the Nix interpreter matching the release wheel's CPython
# tag (python39 / python311 / python314 — see pants/versions.nix).
{ lib, stdenv, fetchurl, makeWrapper, autoPatchelfHook
, patchelf, zlib, util-linux
, interpreter
, pantsVersion, pantsUrl, pantsHash
# Extra interpreters exposed on the wrapper's PATH, e.g. [ python314 ]
# so Pants can discover them for user resolves via interpreter search.
, extraPythons ? [ ]
, deps ? [ ]
}:

let
  python = interpreter;
in
stdenv.mkDerivation rec {
  pname = "pants";
  version = pantsVersion;

  src = fetchurl { url = pantsUrl; hash = pantsHash; };

  # Wheels for the exact Requires-Dist pins (per-version data generated
  # from the pants repo's own lockfile — see scripts/generate.py).
  depWheels = map (d: fetchurl { inherit (d) url hash; }) deps;

  nativeBuildInputs = [ python.pkgs.pip makeWrapper autoPatchelfHook ];
  buildInputs = [ python stdenv.cc.cc.lib ];

  # Interpreter/rpath handed to the named-cache patch sweep below.
  nixInterpreter = stdenv.cc.bintools.dynamicLinker;
  nixRpath = lib.makeLibraryPath [ stdenv.cc.cc.lib zlib ];

  dontConfigure = true;
  dontBuild = true;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    # fetchurl store basenames carry a <hash>- prefix that breaks pip's
    # wheel-filename parsing — stage copies under their original names.
    mkdir -p $out/lib/pants $TMP/wheels
    for w in $src $depWheels; do
      bn=$(basename "$w")
      cp "$w" "$TMP/wheels/''${bn#*-}"
    done

    pip install \
      --no-cache-dir --no-deps --no-index \
      --target $out/lib/pants \
      $TMP/wheels/*.whl

    # Wheels record no exec bits; Pants execs these directly. Older
    # releases may not ship the sandboxer — chmod what exists.
    for f in sandboxer native_client; do
      [ -f $out/lib/pants/pants/bin/$f ] && chmod 0755 $out/lib/pants/pants/bin/$f
    done

    # Pants' loaders unconditionally chmod() embedded binaries next to
    # themselves, which is fatal on the read-only store. Guard every
    # known variant: if the bit is already set (we did, above), skip the
    # syscall. Loader code drifts between releases — patch each pattern
    # where found exactly once, skip when absent, refuse on ambiguity.
    ${python.interpreter} - <<PYEOF
    import pathlib
    import py_compile
    import re

    root = pathlib.Path("$out/lib/pants")
    guards = {
        # pants/bin/pants_loader.py (<= 2.31)
        "os.chmod(sandboxer_bin, 0o755)":
            "if not os.access(sandboxer_bin, os.X_OK):\n                    os.chmod(sandboxer_bin, 0o755)",
        # pants/engine/embedded_binary.py (2.32+)
        "os.chmod(bin_path, 0o755)":
            "if not os.access(bin_path, os.X_OK):\n                os.chmod(bin_path, 0o755)",
    }
    patched = 0
    for py in root.rglob("*.py"):
        try:
            src = py.read_text()
        except OSError:
            continue
        orig = src
        for old, new in guards.items():
            n = src.count(old)
            if n == 1:
                src = src.replace(old, new)
                patched += 1
            elif n > 1:
                raise SystemExit(
                    f"{py}: {n} occurrences of {old[:40]!r}, refusing to patch"
                )
        if src != orig:
            py.write_text(src)
            # pip byte-compiled the ORIGINAL source; regenerate the .pyc
            # so the first launch doesn't recompile the patched module.
            py_compile.compile(str(py), doraise=True)
    # Invariant: no unconditional embedded-binary chmod may ship — the
    # store is read-only and Pants crashes at runtime. Oldest eras
    # (2.21–2.24) predate the loader chmod entirely, so patched == 0 is
    # healthy there; what must never survive is a bare chmod of the
    # embedded binaries outside a known guard.
    for py in root.rglob("*.py"):
        try:
            text = py.read_text(errors="replace")
        except OSError:
            continue
        stripped = text.replace(guards["os.chmod(bin_path, 0o755)"], "").replace(
            guards["os.chmod(sandboxer_bin, 0o755)"], ""
        )
        m = re.search(r"os\.chmod\((bin_path|sandboxer_bin)\b[^)]*0o755", stripped)
        if m:
            raise SystemExit(
                f"{py}: unguarded embedded-binary chmod survived: {m.group(0)!r}"
            )
    print(f"pants loader chmod guards patched: {patched}")
    PYEOF

    mkdir -p $out/bin
    makeWrapper ${python}/bin/python $out/bin/pants \
      --prefix PYTHONPATH : $out/lib/pants \
      --prefix PATH : ${lib.makeBinPath ([ python patchelf stdenv.cc.libc util-linux ] ++ extraPythons)} \
      --set NO_SCIE_WARNING 1 \
      --prefix LD_LIBRARY_PATH : "${nixRpath}" \
      --run "if [ \"\''${PANTS_NIX_AUTOPATCH:-1}\" = 1 ]; then $out/bin/pants-patch-caches; fi" \
      --add-flags "-m pants"

    # Pants' external tools (rustup-managed Rust toolchains, downloaded
    # binaries) live in append-only named caches as generic-Linux ELFs.
    # Without an FHS sandbox those cannot exec; patch their interpreters
    # in place (idempotent, stamp-guarded) so they run Nix-native.
    # Disable with PANTS_NIX_AUTOPATCH=0.
    substituteAll ${./patch-caches.sh} $out/bin/pants-patch-caches
    chmod 0755 $out/bin/pants-patch-caches

    runHook postInstall
  '';

  meta = {
    description = "Pants build system (patchelf-native, no FHS)";
    homepage = "https://www.pantsbuild.org/";
    license = lib.licenses.asl20;
    mainProgram = "pants";
    platforms = [ "x86_64-linux" ];
  };
}
