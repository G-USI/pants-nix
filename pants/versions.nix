# Auto-aggregate: every pants/versions/<version>.nix becomes a package
# data entry keyed by version. Adding a release = dropping its generated
# file into versions/ — no edits to this file needed.
let
  versionFiles = builtins.filter
    (name: builtins.match "[0-9]+.[0-9]+.[0-9]+.nix" name != null)
    (builtins.attrNames (builtins.readDir ./versions));
in
builtins.listToAttrs (
  map (
    f:
    let
      version = builtins.replaceStrings [ ".nix" ] [ "" ] f;
    in
    {
      name = version;
      value = import (./versions + "/${f}");
    }
  ) versionFiles
)
