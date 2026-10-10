#!/usr/bin/env python3
"""fetch_prebuilt.py - download the pre-built Neurus-Lib dependencies.

Neurus-Lib CI publishes, for every commit on `main`, a GitHub release tagged
`lib-<sha12>` carrying one archive per platform:

    windows-x64.zip | macos-arm64.tar.gz | linux-x64.tar.gz

plus a `<archive>.sha256` sibling and a `manifest.json`. Each archive holds
the `prebuilt/<platform>/` tree as its root, so it extracts straight into
`prebuilt/`.

Usage (from anywhere):

    python lib/scripts/fetch_prebuilt.py [--commit SHA | --tag TAG]
                                         [--platform P] [--force] [--skip-verify]

The repository root is derived from this script's location (`scripts/..`).
Unless overridden, the commit is the submodule's own `git rev-parse HEAD`
and the tag is `lib-<sha12>` of that commit, so the binaries always match
the checked-out sources. The download is verified against the release's
`.sha256` (hard fail, before anything is extracted) and, when published,
`manifest.json` is validated against the same commit. A matching
`prebuilt/.version` stamp short-circuits the whole thing unless `--force`
is passed, which makes repeated runs (say, from `make update`) a no-op.

Only the Python standard library is used.
"""

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import tarfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO = "XDzZyq/Neurus-Lib"
RELEASE_API = f"https://api.github.com/repos/{REPO}/releases"
DOWNLOAD_URL = f"https://github.com/{REPO}/releases/download"
VERSION_STAMP = ".version"
MANIFEST_FILE = "manifest.json"

# The producer contract: one archive per platform, named exactly like this.
_ARCHIVES = {
    "windows": "windows-x64.zip",
    "macos": "macos-arm64.tar.gz",
    "linux": "linux-x64.tar.gz",
}

_USER_AGENT = "Neurus-fetch-prebuilt/1.0"


def detect_platform() -> str:
    """Return the current platform identifier (windows, macos, linux)."""
    sysname = platform.system()
    if sysname == "Windows":
        return "windows"
    if sysname == "Darwin":
        return "macos"
    if sysname == "Linux":
        return "linux"
    raise RuntimeError(f"Unsupported platform: {sysname}")


def archive_name(platform: str) -> str:
    """Return the release archive filename for a platform identifier."""
    try:
        return _ARCHIVES[platform]
    except KeyError:
        known = ", ".join(sorted(_ARCHIVES))
        raise ValueError(
            f"Unsupported platform '{platform}' (expected one of: {known})"
        ) from None


def release_tag_for(sha: str) -> str:
    """Return the release tag the producer CI publishes for a commit."""
    return f"lib-{sha[:12]}"


def repo_root_from(script_path: Path) -> Path:
    """Return the repository root, the parent of this script's directory."""
    return Path(script_path).parent.parent


def prebuilt_dir(root: Path) -> Path:
    """Return the directory the platform archives extract into."""
    return Path(root) / "prebuilt"


def version_stamp_path(root: Path) -> Path:
    """Return the path of the installed-version stamp."""
    return prebuilt_dir(root) / VERSION_STAMP


def should_skip(root: Path, tag: str) -> bool:
    """Return True when the stamp already names `tag` (idempotent re-runs)."""
    stamp = version_stamp_path(root)
    if not stamp.exists():
        return False
    lines = stamp.read_text(encoding="utf-8").splitlines()
    return bool(lines) and lines[0].strip() == tag


def verify_sha256(path: Path, expected: str) -> None:
    """Verify a file's SHA-256 digest; raise RuntimeError on mismatch."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    # Get-FileHash emits uppercase; sha256sum emits lowercase.
    if actual != expected.strip().lower():
        raise RuntimeError(
            f"SHA-256 mismatch for {Path(path).name}:\n"
            f"  expected: {expected.strip()}\n"
            f"  actual:   {actual}"
        )


def validate_manifest(manifest: dict, sha: str) -> None:
    """Raise RuntimeError unless the manifest was built from `sha`."""
    built = str(manifest.get("built_from_commit", "")).strip().lower()
    if built != sha.strip().lower():
        raise RuntimeError(
            f"manifest.json mismatch: built_from_commit="
            f"'{manifest.get('built_from_commit')}', expected '{sha}'"
        )


def install(archive_path: Path, root: Path, platform: str) -> None:
    """Replace `prebuilt/<platform>` and extract the archive into `prebuilt/`.

    Only the target platform's tree is cleared, so installing one platform
    never disturbs another's. The archive carries the `<platform>/` tree at
    its root, so it extracts into `prebuilt/` itself.
    """
    prebuilt = prebuilt_dir(root)
    target = prebuilt / platform
    if target.exists():
        shutil.rmtree(target)
    prebuilt.mkdir(parents=True, exist_ok=True)

    if Path(archive_path).suffix == ".zip":
        with zipfile.ZipFile(archive_path) as zf:
            zf.extractall(prebuilt)
    else:
        with tarfile.open(archive_path, "r:*") as tf:
            if hasattr(tarfile, "data_filter"):
                tf.extractall(prebuilt, filter="data")
            else:  # pragma: no cover - Python < 3.12
                tf.extractall(prebuilt)


def head_sha(root: Path) -> str:
    """Return `git -C root rev-parse HEAD`."""
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            f"git rev-parse HEAD failed in {root}: {error.stderr.strip()}"
        ) from error
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

def _asset_url(tag: str, name: str) -> str:
    return f"{DOWNLOAD_URL}/{tag}/{name}"


def _download(url: str, dest: Path) -> bool:
    """Download `url` to `dest`; return False when it does not exist (404)."""
    request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    try:
        with urllib.request.urlopen(request) as response:
            dest.parent.mkdir(parents=True, exist_ok=True)
            with open(dest, "wb") as f:
                shutil.copyfileobj(response, f)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise
    return True


def _read_expected_sha256(path: Path) -> str:
    """Read a digest from a `.sha256` sibling.

    Handles both the `sha256sum` text (`<digest>  <filename>`) and the bare
    digest that `Get-FileHash` output gets written as.
    """
    text = Path(path).read_text(encoding="utf-8").strip()
    if not text:
        raise RuntimeError(f"empty checksum file: {path}")
    return text.split()[0]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Download the pre-built Neurus-Lib dependencies for the "
                    "commit checked out in this repository."
    )
    target = parser.add_mutually_exclusive_group()
    target.add_argument(
        "--commit",
        help="commit to fetch the release for (default: git HEAD)",
    )
    target.add_argument(
        "--tag",
        help="release tag to fetch (default: lib-<sha12> of the target commit)",
    )
    parser.add_argument(
        "--platform",
        choices=sorted(_ARCHIVES),
        help="platform to install (default: the current one)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="reinstall even when the .version stamp already matches",
    )
    parser.add_argument(
        "--skip-verify",
        action="store_true",
        help="skip the .sha256 check (not recommended)",
    )
    args = parser.parse_args(argv)

    root = repo_root_from(Path(__file__).resolve())
    commit = args.commit or head_sha(root)
    tag = args.tag or release_tag_for(commit)
    platform_name = args.platform or detect_platform()
    archive = archive_name(platform_name)

    print("=== Neurus-Lib prebuilt fetch ===")
    print(f"  repo root : {root}")
    print(f"  commit    : {commit}")
    print(f"  tag       : {tag}")
    print(f"  platform  : {platform_name}")

    if should_skip(root, tag) and not args.force:
        print(f"  prebuilt/{VERSION_STAMP} already names {tag}"
              " - nothing to do (use --force to reinstall)")
        return 0

    tmp_dir = prebuilt_dir(root) / ".tmp"
    archive_path = tmp_dir / archive
    try:
        if not _download(_asset_url(tag, archive), archive_path):
            raise SystemExit(
                f"Release '{tag}' has no asset '{archive}'.\n"
                f"Expected a published release '{release_tag_for(commit)}' "
                f"for commit {commit} (see {RELEASE_API}).\n"
                f"URL tried: {_asset_url(tag, archive)}"
            )

        if not args.skip_verify:
            checksum_path = tmp_dir / f"{archive}.sha256"
            if not _download(_asset_url(tag, f"{archive}.sha256"), checksum_path):
                raise SystemExit(
                    f"Release '{tag}' has no '{archive}.sha256' checksum.\n"
                    f"Refusing to install unverified; use --skip-verify to "
                    f"override (see {RELEASE_API})."
                )
            verify_sha256(archive_path, _read_expected_sha256(checksum_path))
            print("  checksum  : OK")

        manifest_path = tmp_dir / MANIFEST_FILE
        if _download(_asset_url(tag, MANIFEST_FILE), manifest_path):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            validate_manifest(manifest, commit)
            print("  manifest  : OK")
        else:
            print("  manifest  : not published (skipped)")

        install(archive_path, root, platform_name)
        stamp = version_stamp_path(root)
        stamp.write_text(f"{tag}\n{commit}\n", encoding="utf-8")
        print(f"  installed : {prebuilt_dir(root) / platform_name}")
        print(f"  stamp     : {stamp}")
        return 0
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
