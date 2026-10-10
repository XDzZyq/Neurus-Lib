# Neurus-Lib

This repository is the dependency root for Neurus. All third-party sources are
pinned as submodules under `src/`; there are no other source trees here.

## Prebuilt libraries

Consumer projects do not build these dependencies from source. Run

```
python scripts/fetch_prebuilt.py
```

to download the prebuilt libraries for the current commit of this repository.
The download is verified against the release's `.sha256` before anything is
extracted.

## Producing the prebuilt libraries

The producer builds run in CI (`.github/workflows/build-libs.yml`). Every push
to `main` — and every manual `workflow_dispatch` run — builds shaderc and the
stamped qtadvanceddocking archives from the pinned `src/` submodules and
publishes a GitHub release tagged `lib-<sha12>`, where `sha12` is the first 12
hex digits of the commit built. Each release carries:

- `windows-x64.zip` and `macos-arm64.tar.gz`, each holding its platform
  directory at the archive root (`windows/…`, `macos/…`), so either archive
  extracts straight into `prebuilt/`;
- a `<archive>.sha256` checksum next to each archive;
- a `manifest.json` recording the built commit, the pinned source submodule
  SHAs, and the ADS compatibility stamp.

`fetch_prebuilt.py` resolves the release for the commit that is checked out, so
the prebuilt libraries always match the pinned sources.
