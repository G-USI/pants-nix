#!/usr/bin/env python3
"""Generate per-version packaging data for stable Pants releases.

Run under nix-backed Python (the driver script does this):

    nix shell nixpkgs#python3 --command python3 scripts/generate.py <tag-file> <repo-root>

For each "release_<tag> <wheel-filename>" input line:
  1. prefetch the release wheel with `nix store prefetch-file` (hash+path),
  2. read Requires-Dist from the wheel's dist-info METADATA (zipfile),
  3. fetch the pants repo's user_reqs.lock for the tag and index its
     exact pins (the build truth; wheel METADATA may be bare/ranged),
  4. for every runtime dep: lock version > METADATA == pin > latest on
      PyPI; select a wheel matching the release's CPython tag; hash it
      with `nix store prefetch-file`,
   5. emit pants/versions/<version>.nix — the aggregate pants/versions.nix
      auto-aggregates the directory via builtins.readDir, nothing to write.

Stdlib only: zipfile, json, re, urllib, subprocess.
"""

import json
import re
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

PYPI_SLEEP = 0.25


def http_json(url: str, tries: int = 3):
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.loads(r.read().decode())
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(1.0 + i)


def nix_prefetch(url: str) -> tuple[str, str]:
    out = subprocess.run(
        ["nix", "store", "prefetch-file", "--hash-type", "sha256", url],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,  # the summary line goes to stderr
        text=True,
        check=True,
    ).stdout
    m = re.search(r"sha256-[A-Za-z0-9+/=]+", out)
    p = re.search(r"(/nix/store/[a-z0-9]+-\S*?\.whl)", out)
    if not m or not p:
        raise RuntimeError(f"prefetch output unparsable for {url}: {out!r}")
    return m.group(0), p.group(1)


def parse_requires_dist(wheel_path: str) -> list[str]:
    """Return the raw requirement specs from the wheel METADATA."""
    with zipfile.ZipFile(wheel_path) as zf:
        meta_name = next(
            n for n in zf.namelist()
            if re.fullmatch(r"[^/]+\.dist-info/METADATA", n)
        )
        lines = zf.read(meta_name).decode().splitlines()
    return [l.split(":", 1)[1].strip() for l in lines if l.startswith("Requires-Dist:")]


def parse_spec(spec: str) -> tuple[str, str]:
    """(name, ==-version or ''). Handles bare names, extras, ranges and
    the parenthesized spec style of older Metadata versions."""
    spec = re.sub(r"[()]", " ", spec).strip()
    m = re.match(r"^([A-Za-z0-9_.\-]+)(\[[^]]*\])?(.*)$", spec)
    if not m:
        raise ValueError(f"unparsable requirement spec {spec!r}")
    name = m.group(1)
    rest = m.group(3)
    vm = re.search(r"==([^;,]+)", rest)
    return name, (vm.group(1).strip() if vm else "")


def lock_data(tag: str) -> dict[str, dict]:
    """Per-dep lock entries from the pants repo lockfile at `tag`.

    v3 lockfiles (JSON body after the metadata banner) carry, per
    requirement: project_name, version and artifacts[] with exact URLs
    and sha256 hex hashes — the complete truth for dep wheels, so PyPI
    resolution is only a fallback for deps missing from the lock.
    """
    url = (
        "https://raw.githubusercontent.com/pantsbuild/pants/"
        f"{tag}/3rdparty/python/user_reqs.lock"
    )
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            text = r.read().decode()
    except Exception as e:
        raise RuntimeError(f"lockfile fetch failed for {tag}: {e}") from e
    if "END PANTS LOCKFILE METADATA" in text:
        text = text.split("END PANTS LOCKFILE METADATA", 1)[1]
    text = text.strip()
    out: dict[str, dict] = {}
    entries: list[dict] = []
    brace = text.find("{")
    if brace != -1:
        try:
            data = json.loads(text[brace:])
        except json.JSONDecodeError:
            data = None
        if data is not None:
            for resolve in data.get("locked_resolves", []):
                entries.extend(resolve.get("locked_requirements", []))
    else:
        # v1-style lockfile: plain "name==version" lines, no artifacts.
        for line in text.splitlines():
            m = re.fullmatch(r"([A-Za-z0-9_.\-]+)==(\S+)", line.strip())
            if m:
                out[m.group(1).lower().replace("_", "-")] = {
                    "version": m.group(2),
                    "artifacts": [],
                }
        return out
    for req in entries:
        name = req.get("project_name") or req.get("name")
        if not name:
            continue
        out[name.lower().replace("_", "-")] = {
            "version": req["version"],
            "artifacts": [
                (a["url"], a["hash"])
                for a in req.get("artifacts", [])
                if a.get("algorithm") == "sha256"
            ],
            "requires_dists": req.get("requires_dists", []),
        }
    return out


def sri_from_hex(hexhash: str) -> str:
    """hex sha256 -> nix SRI form (sha256-<base64>)."""
    import base64

    return "sha256-" + base64.b64encode(bytes.fromhex(hexhash)).decode()


ARCHES = ("x86_64", "aarch64")


def pick_artifact(artifacts: list[tuple[str, str]], cp: str, arch: str) -> tuple[str, str] | None:
    """(url, sri) of the best wheel artifact for the release's CPython tag."""

    def find(pattern: str):
        for u, h in artifacts:
            if re.search(pattern, u.rsplit("/", 1)[-1]):
                return u, sri_from_hex(h)
        return None

    return (
        find(rf"{cp}-{cp}-(manylinux|linux).*{arch}\.whl")
        or find(rf"abi3-manylinux.*{arch}\.whl")
        or find(r"none-any\.whl")
    )


def pick_dep_wheel(urls: list[dict], cp: str, arch: str) -> str | None:
    """URL of the best dependency wheel for the release's CPython tag."""
    def find(pattern: str):
        for u in urls:
            if u.get("packagetype") == "bdist_wheel" and re.search(pattern, u["filename"]):
                return u["url"]
        return None

    return (
        find(rf"{cp}-{cp}-(manylinux|linux).*{arch}")
        or find(rf"abi3-manylinux.*{arch}")
        or find(r"none-any")
    )


def generate(tag: str, wheel_x86: str, wheel_arm: str, outdir: Path) -> str:
    version = tag.removeprefix("release_")
    cp = re.search(r"-(cp\d+)-cp\d+-", wheel_x86)
    if not cp:
        raise ValueError(f"no cp tag in {wheel_x86}")
    cp = cp.group(1)

    def wheel_url(wheel_file: str) -> str:
        return f"https://github.com/pantsbuild/pants/releases/download/{tag}/{wheel_file}"

    x86_hash, x86_path = nix_prefetch(wheel_url(wheel_x86))
    specs = parse_requires_dist(x86_path)
    lock = lock_data(tag)

    # Expand the wheel's direct runtime deps through the lockfile's own
    # requires_dists graph — old-era pins (e.g. packaging<22) pull in
    # transitives like pyparsing that the flat direct list misses.
    def dep_names_of(entry: dict) -> list[str]:
        names = []
        for rd in entry.get("requires_dists", []) or []:
            # PEP 508: requirements behind `extra == "..."` markers are
            # opt-in features of the dependency, never installed at
            # runtime — following them pulled test/type toolchains
            # (mypy, pytest, ...) into every closure.
            _, _, marker = rd.partition(";")
            if "extra" in marker:
                continue
            m = re.match(r"^([A-Za-z0-9_.\-]+)", rd.strip())
            if m:
                names.append(m.group(1).lower().replace("_", "-"))
        return names

    closure: dict[str, dict] = {}
    seed = [parse_spec(s)[0].lower().replace("_", "-").replace(".", "-") for s in specs]
    missing = sorted({n for n in seed if n not in lock})
    if missing:
        raise ValueError(
            f"{tag}: direct deps absent from the lockfile — the closure "
            f"would be silently incomplete: {missing}"
        )
    queue = [n for n in seed if n in lock]
    while queue:
        n = queue.pop(0)
        if n in closure:
            continue
        closure[n] = lock[n]
        queue.extend(x for x in dep_names_of(lock[n]) if x in lock and x not in closure)

    def resolve_arch(arch: str) -> list[tuple[str, str, str]]:
        deps = []
        for norm in sorted(closure):
            entry = closure[norm]
            picked = pick_artifact(entry["artifacts"], cp, arch)
            if picked:
                deps.append((norm, *picked))
                continue
            # Locked release predates the interpreter (e.g. hdrhistogram
            # 0.10.3 has no cp314 wheels): resolve the locked version on
            # PyPI and bump to the first newer release shipping a wheel.
            ver = entry["version"]
            rel = http_json(f"https://pypi.org/pypi/{norm}/{ver}/json")
            dep_url = pick_dep_wheel(rel["urls"], cp, arch)
            bumped_from = None
            if not dep_url:
                all_rels = http_json(f"https://pypi.org/pypi/{norm}/json")["releases"]
                order = sorted(
                    all_rels,
                    key=lambda v: [
                        (int(x) if x.isdigit() else 0, x if not x.isdigit() else "")
                        for x in re.split(r"[.\-]", v)
                    ],
                )
                start = order.index(ver) + 1 if ver in order else 0
                for cand in order[start:]:
                    dep_url = pick_dep_wheel(all_rels[cand], cp, arch)
                    if dep_url:
                        bumped_from, ver = ver, cand
                        break
            if not dep_url:
                raise ValueError(f"no {arch} {cp} wheel for {norm}=={ver}")
            dep_hash, _ = nix_prefetch(dep_url)
            if bumped_from is not None:
                print(
                    f"  note: {arch} {norm} bumped {bumped_from} -> {ver} for {cp}",
                    file=sys.stderr,
                    flush=True,
                )
            deps.append((norm, dep_url, dep_hash))
            time.sleep(PYPI_SLEEP)
        return deps

    x86_deps = resolve_arch("x86_64")
    try:
        arm_deps = resolve_arch("aarch64")
    except ValueError as e:
        arm_deps = None
        print(
            f"  note: aarch64 unavailable for {version} — emitting null: {e}",
            file=sys.stderr,
            flush=True,
        )

    def fmt_arch(platform: str, url: str, whash: str, deps: list[tuple[str, str, str]]) -> str:
        body = "".join(
            f'    {{ name = "{n}"; url = "{u}"; hash = "{h}"; }}\n' for n, u, h in deps
        )
        return (
            f"  {platform} = {{\n"
            f'    url = "{url}";\n'
            f'    hash = "{whash}";\n'
            "    deps = [\n"
            f"{body}"
            "    ];\n"
            "  };\n"
        )

    parts = [fmt_arch("x86_64-linux", wheel_url(wheel_x86), x86_hash, x86_deps)]
    if arm_deps is None:
        parts.append("  aarch64-linux = null;\n")
    else:
        arm_hash, _ = nix_prefetch(wheel_url(wheel_arm))
        parts.append(fmt_arch("aarch64-linux", wheel_url(wheel_arm), arm_hash, arm_deps))

    outdir.joinpath(f"{version}.nix").write_text(
        f"# Generated by scripts/generate.py from {tag} — do not edit.\n"
        "{\n"
        f'  python = "python{cp.removeprefix("cp")}";\n'
        + "".join(parts)
        + "}\n"
    )
    return f"OK {version} ({cp}, x86_64: {len(x86_deps)} deps, aarch64: {'—' if arm_deps is None else f'{len(arm_deps)} deps'})"


def main() -> int:
    tag_file, repo_root = Path(sys.argv[1]), Path(sys.argv[2])
    outdir = repo_root / "pants" / "versions"
    outdir.mkdir(parents=True, exist_ok=True)

    failures = []
    for line in tag_file.read_text().splitlines():
        if not line.strip():
            continue
        tag, wheel_x86, wheel_arm = line.split()
        try:
            print(generate(tag, wheel_x86, wheel_arm, outdir), flush=True)
        except Exception as e:  # noqa: BLE001 - report and continue
            failures.append((tag, str(e)))
            print(f"FAIL {tag}: {e}", file=sys.stderr, flush=True)

    # The aggregate index (pants/versions.nix) auto-aggregates this
    # directory via builtins.readDir — nothing to write here.
    print(f"DONE: {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
