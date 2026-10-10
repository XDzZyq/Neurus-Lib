# Neurus-Lib

This repository is the dependency root for Neurus. All third-party sources are
pinned as submodules under `src/`; there are no other source trees here.

## Prebuilt libraries

Consumer projects do not build these dependencies from source. Run

```
python scripts/fetch_prebuilt.py
```

to download the prebuilt libraries for the current commit of this repository.
The producer builds that publish those prebuilt libraries run in CI.
