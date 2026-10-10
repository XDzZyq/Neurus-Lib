#!/usr/bin/env python3
"""generate_manifest.py - build the manifest.json for a Neurus-Lib release.

The producer CI (`.github/workflows/build-libs.yml`) publishes, for every
commit on `main`, one GitHub release tagged `lib-<sha12>` carrying the prebuilt
platform archives and a `manifest.json`. This script generates that manifest
from the release job's downloaded artifacts:

    python scripts/generate_manifest.py \
        --artifacts artifacts \
        --out release/manifest.json \
        --tag lib-<sha12> \
        --commit <full 40-hex sha>

- `tag` / `built_from_commit` are passed in; the commit must be the full 40-hex
  SHA because the consumer (`scripts/fetch_prebuilt.py`) validates it against
  the checked-out commit exactly.
- `sources` records the pinned submodule SHAs as `git submodule status` reports
  them for the checked-out commit (the leading marker is checkout state, not
  part of the SHA).
- `ads_stamp` records the ADS compatibility stamp (`build_info.txt`) of each
  platform's build, keyed by platform; every stamp must carry `qt_version`,
  `cxx_standard`, `ads_version` and `compiler` or the script fails.

Only the Python standard library is used.
"""

import argparse
import json
import subprocess
from pathlib import Path

# The platforms a release carries, in manifest order.
PLATFORMS = ("windows", "macos")

# The ADS compatibility keys every build_info.txt stamp must carry: the
# consuming build refuses an archive whose stamp lacks them.
REQUIRED_STAMP_KEYS = ("qt_version", "cxx_standard", "ads_version", "compiler")


def parse_submodule_status(text: str) -> dict[str, str]:
    """Return `src/<name>` -> SHA parsed from `git submodule status` output.

    Each line is `[ +-U]<40-hex-sha> <path> (describe)`: the leading marker
    records checkout state (uninitialized / mismatched / conflicted), not the
    SHA, so it is stripped before the SHA is recorded.
    """
    sources = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            sources[parts[1]] = parts[0].lstrip("+-U")
    return sources


def parse_stamp(text: str) -> dict[str, str]:
    """Return the flat `key=value` pairs of an ADS build_info.txt stamp.

    `#` comments and blank (or non-`=`) lines are skipped.
    """
    stamp = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        stamp[key.strip()] = value.strip()
    return stamp


def build_manifest(tag: str, commit: str, sources: dict, ads_stamp: dict) -> dict:
    """Return the release manifest carrying exactly the contracted keys."""
    return {
        "tag": tag,
        "built_from_commit": commit,
        "platform": list(PLATFORMS),
        "sources": sources,
        "ads_stamp": ads_stamp,
    }


def write_manifest(manifest: dict, out_path: Path) -> None:
    """Write the manifest as indented, key-sorted JSON with a trailing newline."""
    text = json.dumps(manifest, indent=2, sort_keys=True)
    Path(out_path).write_text(text + "\n", encoding="utf-8")


def collect_ads_stamps(artifacts: Path) -> dict[str, dict[str, str]]:
    """Return platform -> ADS stamp from the downloaded build artifacts.

    Each build leg uploads `prebuilt/<platform>/qtadvanceddocking/build_info.txt`
    inside its `prebuilt-<platform>` artifact, downloaded to
    `<artifacts>/<platform>/`. Fails (SystemExit) when a stamp is missing or
    lacks a required key, so a release can never ship a manifest the consumer
    cannot trust.
    """
    stamps = {}
    for platform in PLATFORMS:
        stamp_path = (Path(artifacts) / platform / "prebuilt" / platform
                      / "qtadvanceddocking" / "build_info.txt")
        if not stamp_path.is_file():
            raise SystemExit(f"missing ADS stamp for {platform}: {stamp_path}")
        stamp = parse_stamp(stamp_path.read_text(encoding="utf-8"))
        missing = [key for key in REQUIRED_STAMP_KEYS if key not in stamp]
        if missing:
            raise SystemExit(f"{stamp_path}: missing {', '.join(missing)}")
        stamps[platform] = stamp
    return stamps


def submodule_sources() -> dict[str, str]:
    """Return `src/<name>` -> SHA for the repository in the current directory."""
    status = subprocess.run(
        ["git", "submodule", "status"],
        check=True, capture_output=True, text=True,
    ).stdout
    return parse_submodule_status(status)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate the release manifest.json from the downloaded "
                    "prebuilt build artifacts."
    )
    parser.add_argument(
        "--artifacts",
        type=Path,
        default=Path("artifacts"),
        help="directory holding the downloaded artifact trees "
             "(default: artifacts)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("release/manifest.json"),
        help="where to write manifest.json (default: release/manifest.json)",
    )
    parser.add_argument(
        "--tag",
        required=True,
        help="release tag (lib-<sha12>)",
    )
    parser.add_argument(
        "--commit",
        required=True,
        help="full 40-hex commit SHA the release was built from",
    )
    args = parser.parse_args(argv)

    manifest = build_manifest(
        tag=args.tag,
        commit=args.commit,
        sources=submodule_sources(),
        ads_stamp=collect_ads_stamps(args.artifacts),
    )
    write_manifest(manifest, args.out)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
