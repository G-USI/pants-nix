# pants-nix

Run the [Pants](https://www.pantsbuild.org/) build system from Nix —
natively on any Linux machine, NixOS included. Every stable Pants
release from **2.21.0 through 2.33.1** is packaged, each on the
interpreter its release wheel requires (python 3.9 / 3.11 / 3.14).

## Quick start

Ad-hoc (defaults to the newest packaged release):

```console
$ nix run github:G-USI/pants-nix -- --version
2.33.1
```

A specific version (dots become underscores):

```console
$ nix shell github:G-USI/pants-nix#pants-2_31_0 --command pants --version
2.31.0
```

## Using it in your repo

Add the input:

```nix
inputs.pants-nix.url = "github:G-USI/pants-nix";
```

Bind Pants to the version your repo pins — point `fromPantsToml` at
your `pants.toml`. Bumping `[GLOBAL].pants_version` re-resolves the
package on the next eval. Note the file must be **tracked by git** —
untracked files are invisible to flake source and eval fails with a
missing-file error:

```nix
devShells.x86_64-linux.default =
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    pkgs39 = pants-nix.inputs.nixpkgs-py39.legacyPackages.x86_64-linux;
  in
  pkgs.mkShell {
    packages = [
      (pants-nix.lib.fromPantsToml pkgs pkgs39 ./pants.toml)
      pkgs.python314   # interpreters your resolves need
      pkgs.cargo       # toolchains sandboxed processes need
      pkgs.rustc
    ];
  };
```

Or pick a version explicitly:

```nix
packages = [ (pants-nix.lib.mkPants pkgs pkgs39 { version = "2.31.0"; }) ];
```

Both build against **your** nixpkgs. If you want store paths identical
across machines — the precondition for a shared binary cache — use the
pinned builders, which build against this flake's nixpkgs instead:

```nix
packages = [ (pants-nix.pinned.x86_64-linux.fromPantsToml ./pants.toml) ];
```

If your `pants.toml` lives outside a git-tracked path (e.g. a bare
repo without commits), pin explicitly with `pinned.mkPantsPinned
{ version = "…"; }`.

devenv works the same way: add the input, then put the built package
into `devenv.nix`'s `packages` list.

### New Pants releases

Regenerate the version data and commit it:

```console
$ scripts/list-versions.sh > /tmp/versions.txt
$ scripts/gen-versions.sh /tmp/versions.txt
$ git add pants/versions/
```

Unknown versions then fail loudly if not generated.

## Runtime behavior

- Pants boots on a Nix interpreter and executes the release wheel's
  native engine, patchelf'd against Nix libraries at build time.
- On launch (synchronously, before Pants starts), `pants-patch-caches`
  rewrites generic-Linux binaries Pants downloads into its caches
  (rustup toolchains, interpreters reused by PEX venvs): the
  interpreter becomes the Nix glibc loader and the Nix lib dir is
  **appended** to existing rpaths; shared objects are touched only
  when `ldd` proves unresolvable needs. Atomic, stamp-guarded,
  single-flight — a warm run is a no-op, so the synchronous launch
  costs nothing once caches are patched. Disable with
  `PANTS_NIX_AUTOPATCH=0`. Run it by hand any time with
  `$(nix build --print-out-paths <flake>#pkg)/bin/pants-patch-caches`;
  it reports how many binaries and shared objects it patched.
- Expose the interpreters your resolves need via `extraPythons`
  (`extraPythons = [ pkgs.python314 ];`).
- **Point every downloaded-tool plugin at PATH binaries.** Any Pants
  plugin that downloads an external tool (nodejs, terraform, helm, …)
  will otherwise fetch a generic-Linux binary that cannot run on NixOS.
  The standard pattern works per subsystem: set its version to one
  **outside** the plugin's `known_versions` (e.g.
  `PANTS_NODEJS_VERSION=24.14.0` — only `v24.10.0` is known for nodejs
  in 2.31) and provide the real binary via the PATH of whatever shell
  invokes Pants (e.g. nix `nodejs` in your devenv). Pants then searches PATH, version-tests the binary, and
  runs it Nix-native. Expect to do this for each downloaded-tool plugin
  your repo enables — leaving any of them on the download path is the
  likely source of `Could not start dynamically linked executable`
  errors on NixOS.
- Tool venvs are cached per constraints — invoke Pants with a
  consistent interpreter set to avoid re-materialization.

## Requirements & limitations

- x86_64-linux only; macOS is not supported (the release wheels are
  manylinux).
- One interpreter per Pants version (the release wheel's CPython tag):
  2.21–2.24 → python3.9 (built via the `nixpkgs-py39` input),
  2.25–2.31 → python3.11, 2.32+ → python3.14.
- A `pants` launcher already on PATH shadows this package's binary —
  in shells where both exist, check `which pants`.
- Pants still downloads your resolves at runtime (as upstream); they
  live in Pants' caches, not the Nix store. Downloaded-tool plugins
  (see Runtime behavior) must be re-pointed at PATH binaries — on
  NixOS the download-and-exec path fails out of the box.
