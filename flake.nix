{
  description = "Pants build system on Nix — FHS-free, patchelf-native";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Known release-wheel hashes per Pants version. pants/build
      # validates `pantsHash` — add a version here (from
      # `nix store prefetch-file` on the release wheel URL) to make it
      # usable via fromPantsToml / mkPants without passing a hash.
      wheelHashes = import ./versions.nix;

      mkPants =
        pkgs:
        {
          version,
          hash ? wheelHashes.${version} or (throw "pants-nix: unknown pants version ${version} — add its wheel hash to versions.nix"),
          extraPythons ? [ ],
        }:
        pkgs.callPackage ./pants {
          pantsVersion = version;
          pantsHash = hash;
          inherit extraPythons;
        };
    in
    {
      lib = {
        inherit mkPants wheelHashes;
        # Read a repo's pants.toml and build exactly the pinned version:
        #   pants-nix.lib.fromPantsToml pkgs ./pants.toml
        # Changing [GLOBAL].pants_version in the toml re-resolves the
        # package on the next eval; unknown versions fail loudly with the
        # instruction above.
        fromPantsToml =
          pkgs: tomlPath:
          let
            pantsToml = builtins.fromTOML (builtins.readFile tomlPath);
            global = pantsToml.GLOBAL or pantsToml.global or null;
            version =
              if global == null then
                throw "pants-nix: no [GLOBAL] section in ${toString tomlPath}"
              else
                global.pants_version;
          in
          mkPants pkgs { inherit version; };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          pants-2_31_0 = mkPants pkgs { version = "2.31.0"; };
          default = self.packages.${system}.pants-2_31_0;
        }
      );

      apps = forAllSystems (
        system:
        rec {
          pants = {
            type = "app";
            program = nixpkgs.lib.getExe self.packages.${system}.default;
          };
          default = pants;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Pants itself + python3.14 on PATH so the interpreter search
          # can satisfy CPython==3.14.* resolves in downstream repos, and
          # the Rust toolchain so sandboxed cargo invocations use Nix
          # binaries (generic-Linux rustup cargo cannot run on NixOS
          # without an FHS sandbox).
          default = pkgs.mkShell {
            packages = [
              (mkPants pkgs {
                version = "2.31.0";
                extraPythons = [ pkgs.python314 ];
              })
              pkgs.cargo
              pkgs.rustc
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          version-smoke = pkgs.runCommand "pants-version-smoke"
            {
              nativeBuildInputs = [ self.packages.${system}.default ];
              # pantsd's socket bootstrap does not survive the check
              # sandbox; the version goal does not need it. The sandbox
              # HOME (/homeless-shelter) is not writable — pants needs a
              # writable ~/.cache/pants for its LMDB store.
              PANTS_PANTSD = "false";
              HOME = "/build";
            }
            ''
              mkdir -p project && cd project
              printf '[GLOBAL]\npants_version = "2.31.0"\n' > pants.toml
              pants --version > version.out
              grep -qx 2.31.0 version.out || {
                echo "unexpected version:"; cat version.out; exit 1;
              }
              cp version.out $out
            '';
        }
      );
    };
}
