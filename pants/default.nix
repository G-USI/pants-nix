# Pants, packaged from the official GitHub-release wheel — no FHS.
#
# The native engine (pants/bin/native_client) and native dependency
# extensions (libcst, psutil, setproctitle, hdrhistogram) are patchelf'd
# against Nix libraries by autoPatchelfHook. Pants runs on the Nix
# python311 interpreter (the wheel is cp311; Pants 2.31 pins
# Requires-Python ==3.11.*).
{ lib, stdenv, fetchurl, python311, makeWrapper, autoPatchelfHook
, patchelf, zlib
, pantsVersion, pantsHash
# Extra interpreters exposed on the wrapper's PATH, e.g. [ python314 ]
# so Pants can discover them for user resolves via interpreter search.
, extraPythons ? [ ]
, deps ? import ./deps.nix
}:

stdenv.mkDerivation rec {
  pname = "pants";
  version = pantsVersion;

  src = fetchurl {
    url = "https://github.com/pantsbuild/pants/releases/download/release_${version}/pantsbuild_pants-${version}-cp311-cp311-manylinux2014_x86_64.whl";
    hash = pantsHash;
  };

  # Wheels for the exact Requires-Dist pins (see deps.nix).
  depWheels = map (d: fetchurl { inherit (d) url hash; }) deps;

  nativeBuildInputs = [ python311.pkgs.pip makeWrapper autoPatchelfHook ];
  buildInputs = [ python311 stdenv.cc.cc.lib ];

  # Interpreter/rpath handed to the named-cache patch sweep below.
  nixInterpreter = "${stdenv.cc.libc}/lib/ld-linux-x86-64.so.2";
  nixRpath = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    zlib
  ];

  dontConfigure = true;
  dontBuild = true;
  dontUnpack = true;

  # The engine reads argv[0] to decide some bootstrap behavior; keep the
  # binary named `pants` and let `python -m pants` handle the rest.
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

    # Wheels record no exec bits; Pants execs these directly.
    chmod 0755 $out/lib/pants/pants/bin/sandboxer $out/lib/pants/pants/bin/native_client

    # Pants' loader unconditionally chmod()s the sandboxer next to itself,
    # which is fatal on the read-only store. Guard it: if the bit is
    # already set (we did, above), skip the syscall.
    ${python311.interpreter} - <<PYEOF
    path = "$out/lib/pants/pants/bin/pants_loader.py"
    src = open(path).read()
    old = "os.chmod(sandboxer_bin, 0o755)"
    new = "if not os.access(sandboxer_bin, os.X_OK):\n                    os.chmod(sandboxer_bin, 0o755)"
    assert src.count(old) == 1, "pants_loader patch target not found"
    open(path, "w").write(src.replace(old, new))
    PYEOF

    mkdir -p $out/bin
    makeWrapper ${python311}/bin/python $out/bin/pants \
      --prefix PYTHONPATH : $out/lib/pants \
      --prefix PATH : ${lib.makeBinPath ([ python311 patchelf ] ++ extraPythons)} \
      --set NO_SCIE_WARNING 1 \
      --run 'if [ "''${PANTS_NIX_AUTOPATCH:-1}" = 1 ]; then $out/bin/pants-patch-caches >/dev/null 2>&1 || true; fi' \
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

  # autoPatchelfHook's fixup phase scans $out and rewrites every ELF it
  # finds (engine + native extension modules) against the buildInputs.

  meta = {
    description = "Pants build system (patchelf-native, no FHS)";
    homepage = "https://www.pantsbuild.org/";
    license = lib.licenses.asl20;
    mainProgram = "pants";
    platforms = [ "x86_64-linux" ];
  };
}
