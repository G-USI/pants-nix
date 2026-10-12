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
  5. emit pants/versions/<version>.nix, and finally the aggregate
     pants/versions.nix index.

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
    except Exception:
        return {}
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


def pick_artifact(artifacts: list[tuple[str, str]], cp: str) -> tuple[str, str] | None:
    """(url, sri) of the best wheel artifact for the release's CPython tag."""

    def find(pattern: str):
        for u, h in artifacts:
            if re.search(pattern, u.rsplit("/", 1)[-1]):
                return u, sri_from_hex(h)
        return None

    return (
        find(rf"{cp}-{cp}-(manylinux|linux).*x86_64\.whl")
        or find(r"abi3-manylinux.*x86_64\.whl")
        or find(r"none-any\.whl")
    )


def pick_dep_wheel(urls: list[dict], cp: str) -> str | None:
    """URL of the best dependency wheel for the release's CPython tag."""
    def find(pattern: str):
        for u in urls:
            if u.get("packagetype") == "bdist_wheel" and re.search(pattern, u["filename"]):
                return u["url"]
        return None

    return (
        find(rf"{cp}-{cp}-(manylinux|linux).*x86_64")
        or find(r"abi3-manylinux.*x86_64")
        or find(r"none-any")
    )


def generate(tag: str, wheel_file: str, outdir: Path) -> str:
    version = tag.removeprefix("release_")
    cp = re.search(r"-(cp\d+)-cp\d+-", wheel_file)
    if not cp:
        raise ValueError(f"no cp tag in {wheel_file}")
    cp = cp.group(1)

    url = f"https://github.com/pantsbuild/pants/releases/download/{tag}/{wheel_file}"
    wheel_hash, wheel_path = nix_prefetch(url)

    specs = parse_requires_dist(wheel_path)
    lock = lock_data(tag)

    # Expand the wheel's direct runtime deps through the lockfile's own
    # requires_dists graph — old-era pins (e.g. packaging<22) pull in
    # transitives like pyparsing that the flat direct list misses.
    def dep_names_of(entry: dict) -> list[str]:
        names = []
        for rd in entry.get("requires_dists", []) or []:
            m = re.match(r"^([A-Za-z0-9_.\-]+)", rd.strip())
            if m:
                names.append(m.group(1).lower().replace("_", "-"))
        return names

    closure: dict[str, dict] = {}
    seed = [parse_spec(s)[0].lower().replace("_", "-").replace(".", "-") for s in specs]
    queue = [n for n in seed if n in lock]
    while queue:
        n = queue.pop(0)
        if n in closure:
            continue
        closure[n] = lock[n]
        queue.extend(x for x in dep_names_of(lock[n]) if x in lock and x not in closure)

    deps = []
    for norm in sorted(closure):
        entry = closure[norm]
        picked = pick_artifact(entry["artifacts"], cp)
        if picked:
            deps.append((norm, *picked))
            continue
        # Locked release predates the interpreter (e.g. hdrhistogram
        # 0.10.3 has no cp314 wheels): resolve the locked version on
        # PyPI and bump to the first newer release shipping a wheel.
        ver = entry["version"]
        rel = http_json(f"https://pypi.org/pypi/{norm}/{ver}/json")
        dep_url = pick_dep_wheel(rel["urls"], cp)
        bumped_from = None
        if not dep_url:
            all_rels = http_json(f"https://pypi.org/pypi/{norm}/json")["releases"]
            order = sorted(
                all_rels,
                key=lambda v: [int(x) if x.isdigit() else x for x in re.split(r"[.\-]", v)],
            )
            start = order.index(ver) + 1 if ver in order else 0
            for cand in order[start:]:
                dep_url = pick_dep_wheel(all_rels[cand], cp)
                if dep_url:
                    bumped_from, ver = ver, cand
                    break
        if not dep_url:
            raise ValueError(f"no {cp} wheel for {norm}=={ver}")
        dep_hash, _ = nix_prefetch(dep_url)
        if bumped_from is not None:
            print(
                f"  note: {norm} bumped {bumped_from} -> {ver} for {cp}",
                file=sys.stderr,
                flush=True,
            )
        deps.append((norm, dep_url, dep_hash))
        time.sleep(PYPI_SLEEP)

    body = "".join(
        f'  {{ name = "{n}"; url = "{u}"; hash = "{h}"; }}\n' for n, u, h in deps
    )
    outdir.joinpath(f"{version}.nix").write_text(
        f"# Generated by scripts/generate.py from {tag} — do not edit.\n"
        "{\n"
        f'  url = "{url}";\n'
        f'  hash = "{wheel_hash}";\n'
        f'  python = "python{cp.removeprefix("cp")}";\n'
        "  deps = [\n"
        f"{body}"
        "  ];\n"
        "}\n"
    )
    return f"OK {version} ({cp}, {len(deps)} deps)"


def main() -> int:
    tag_file, repo_root = Path(sys.argv[1]), Path(sys.argv[2])
    outdir = repo_root / "pants" / "versions"
    outdir.mkdir(parents=True, exist_ok=True)

    failures = []
    for line in tag_file.read_text().splitlines():
        if not line.strip():
            continue
        tag, wheel_file = line.split()
        try:
            print(generate(tag, wheel_file, outdir), flush=True)
        except Exception as e:  # noqa: BLE001 - report and continue
            failures.append((tag, str(e)))
            print(f"FAIL {tag}: {e}", file=sys.stderr, flush=True)

    # Index every generated file (not just this run's) so partial
    # reruns keep the aggregate complete.
    ok = sorted(p.stem for p in outdir.glob("*.nix"))
    index = "".join(f'  "{v}" = import ./versions/{v}.nix;\n' for v in ok)
    (repo_root / "pants" / "versions.nix").write_text(
        "# Generated by scripts/generate.py — do not edit.\n"
        "# Maps every packaged Pants version to its release data.\n"
        "{\n" + index + "}\n"
    )
    print(f"DONE: {len(ok)} versions, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
