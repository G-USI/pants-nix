# pants-nix

The [Pants](https://www.pantsbuild.org/) build system on NixOS — **without
an FHS sandbox**. Pants runs Nix-native: the official release wheel's
native engine is patchelf'd against Nix libraries at build time, and
runtime-downloaded tools in Pants' append-only caches are patched
in place (idempotently) by a wrapper hook.

## Usage

Ad-hoc:

```console
$ nix run github:G-USI/pants-nix -- --version
2.31.0
```

In a flake:

```nix
{
  inputs.pants-nix.url = "github:G-USI/pants-nix";

  outputs = { self, nixpkgs, pants-nix }: {
    devShells.x86_64-linux.default =
      let pkgs = nixpkgs.legacyPackages.x86_64-linux; in
      pkgs.mkShell {
        packages = [ (pants-nix.lib.mkPants pkgs { version = "2.31.0"; }) ];
      };
  };
}
```

Driven by your repo's `pants.toml` (re-resolves when you bump
`[GLOBAL].pants_version`):

```nix
pants-nix.lib.fromPantsToml pkgs ./pants.toml
```

Unknown versions fail loudly — add the release-wheel hash to
`versions.nix` (command in that file's header).

## How it works

- Packages the `pantsbuild_pants-<ver>-cp311-cp311-manylinux2014_x86_64.whl`
  GitHub-release artifact with `pip install --target` onto Nix `python311`
  (Pants pins `Requires-Python ==3.11.*`).
- `autoPatchelfHook` rewrites the native engine
  (`pants/bin/native_client`) and native dependency extensions (libcst,
  psutil, setproctitle, hdrhistogram) against Nix glibc/libstdc++.
- The `pants` binary is a `python -m pants` wrapper with
  `NO_SCIE_WARNING=1` (Pants otherwise refuses non-scie launches).
- The wheel records no exec bits and its loader `chmod()`s a bundled
  sandboxer next to itself — both are handled at build time (pre-chmod +
  a small loader patch), because the store is read-only.
- Pants' external tools (rustup-managed Rust toolchains, etc.) land in
  `~/.cache/pants/named_caches` as generic-Linux binaries. The wrapper
  runs `pants-patch-caches` before every launch: patchelf's their
  interpreters/rpaths to Nix paths, stamp-guarded and idempotent
  (disable with `PANTS_NIX_AUTOPATCH=0`). Patched binaries also keep
  working inside FHS environments, so mixed setups are safe.
- Extra interpreters (e.g. `python314`) can be exposed via
  `extraPythons` so Pants' interpreter search can satisfy user resolves.

## Limitations

- x86_64-linux only (deps.nix wheels are x86_64).
- One Pants version per package; `versions.nix` maps known versions to
  wheel hashes.
- Fully-hermetic (no-network) nix builds of *user* resolves are out of
  scope: Pants downloads distributions at runtime like it always does.
