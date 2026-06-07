# ziti-sdk-c-binary-cache

A shared [vcpkg](https://vcpkg.io) **binary cache** for [ziti-sdk-c](https://github.com/openziti/ziti-sdk-c)'s
native dependencies (openssl, libuv, protobuf-c, etc.). It exists so ziti-sdk-c, ziti-sdk-csharp,
ziti-tunnel-sdk-c, and individual developers don't each recompile those deps from scratch on every build.

## TL;DR

Prebuilt openssl/libuv/protobuf-c/etc so you don't recompile them. Run one line from your repo root (the dir
with the `vcpkg.json` you build against), then `cmake`/`vcpkg` as normal:

```bash
# Linux / macOS - SOURCE it so the export sticks
source <(curl -fsSL https://raw.githubusercontent.com/openziti/ziti-sdk-c-binary-cache/main/scripts/restore-cache.sh)
```
```powershell
# Windows - dot-source via iex
iex (irm https://raw.githubusercontent.com/openziti/ziti-sdk-c-binary-cache/main/scripts/restore-cache.ps1)
```
```yaml
# GitHub Actions
- uses: openziti/ziti-sdk-c-binary-cache/restore@main
  with: { vcpkg-json: vcpkg.json, rid: linux-x64 }
```

It auto-detects your RID, reads the baseline from your `vcpkg.json`, downloads the matching tarball, and sets
`VCPKG_BINARY_SOURCES`. No auth. A miss just means vcpkg builds those deps itself - never a wrong binary. You
hit the cache only if you build in the same env ziti-sdk-c releases from (baseline + triplet + runner image);
details below.

## How it works

This repo is the **producer**. `.github/workflows/build-cache.yml` runs daily (and on manual dispatch). To
guarantee the cached deps have the exact ABI ziti-sdk-c ships, it does not hand-roll `vcpkg install`: it checks
out ziti-sdk-c and runs **ziti-sdk-c's own release build action** (`./.github/actions/build`) for each published
target, on the same runners and builder containers ziti-sdk-c releases from. That action already writes a vcpkg
`files` binary cache to `.ci.cache`; the producer harvests that directory and publishes it as a tarball on this
repo's own Releases. Because it reuses ziti-sdk-c's build verbatim, there is zero preset/triplet/toolchain drift.
Everyone else is a **pure anonymous reader** - no token needed to pull, and no cross-repo push auth needed to
produce (the producer writes to its own releases with the plain `GITHUB_TOKEN`).

- **One release per vcpkg baseline.** The release is tagged `baseline-<builtin-baseline>` (GitHub forbids a
  tag that is exactly 40/64 hex chars, so the bare baseline can't be the tag), read from ziti-sdk-c's
  `vcpkg.json`, and each holds one `<rid>.tgz` per RID. Any consumer that shares the baseline reuses the same
  deps; a baseline bump lands in its own release, and pruning a stale baseline is just deleting that release.
- Pull URL: `https://github.com/openziti/ziti-sdk-c-binary-cache/releases/download/baseline-<baseline>/<rid>.tgz`

## Using it (consumers + developers)

A script does the whole dance for you: detect your RID, read the baseline from your `vcpkg.json`, download the
matching tarball, extract it, and set `VCPKG_BINARY_SOURCES` in your shell. Then build normally - vcpkg replays
the cached deps instead of compiling them. No auth, no login; the release is public. **Run it from your repo
root** (the dir holding the `vcpkg.json` you build against) so it finds the baseline and exports into your shell.

### Linux / macOS (bash or zsh)

Needs `curl` + `tar` (`jq` optional). It must be **sourced** so the export lands in your shell. No clone needed:

```bash
source <(curl -fsSL https://raw.githubusercontent.com/openziti/ziti-sdk-c-binary-cache/main/scripts/restore-cache.sh)
# build against a different manifest? pass its path (positional args flow through the curl form too):
source <(curl -fsSL https://raw.githubusercontent.com/openziti/ziti-sdk-c-binary-cache/main/scripts/restore-cache.sh) path/to/vcpkg.json
```

Cloned the repo works the same, and lets you override via env `RID` / `ZITI_CACHE_DIR` / `ZITI_CACHE_TAG`:

```bash
source scripts/restore-cache.sh                          # ./vcpkg.json, RID auto-detected
source scripts/restore-cache.sh path/to/vcpkg.json
```

### Windows (PowerShell 5.1+ or 7)

Windows 10+ ships `curl`/`tar`. **Dot-source** it (or `iex` the one-liner) so `$env:VCPKG_BINARY_SOURCES` sticks:

```powershell
# no clone:
iex (irm https://raw.githubusercontent.com/openziti/ziti-sdk-c-binary-cache/main/scripts/restore-cache.ps1)
# cloned (dot-source; lets you pass -VcpkgJson / -Rid):
. .\scripts\restore-cache.ps1
. .\scripts\restore-cache.ps1 -VcpkgJson native\ZitiNativeApiForDotnetCore\vcpkg.json
```

RID is auto-detected; override with `RID=...` (bash) or `-Rid` (pwsh). Valid RIDs: `linux-x64`, `linux-arm`,
`linux-arm64`, `osx-arm64`, `osx-x64`, `win-x64`, `win-x86`, `win-arm64`. A miss (no asset for your
baseline+RID) is fine: vcpkg just builds those deps and fills the dir. Prefer to do it by hand? It is only:
download `<rid>.tgz` from the release tagged with your baseline, `tar -xz` into a dir, and set
`VCPKG_BINARY_SOURCES=clear;files,<dir>,readwrite`.

### Then build - that's the whole point

**There is no separate "use the package" step.** This is a vcpkg *binary cache*, not an SDK: the extracted dir
is a pile of prebuilt dependency archives (`openssl`, `libuv`, `protobuf-c`, ...) named by vcpkg's ABI hash. You
do not include or link it directly. You consume it simply by **building as you normally would** in the same
shell - vcpkg sees `VCPKG_BINARY_SOURCES` and replays each dependency from the dir instead of compiling it:

```bash
# after the restore step above, in the SAME shell:
cmake --preset ci-linux-x64 -B build      # ziti-sdk-c; or your own project's configure / `vcpkg install`
cmake --build build
# vcpkg restores openssl/libuv/protobuf-c/... from the cache; the slow first build becomes minutes, not an hour
```

Two things to know:
- It must be the **same shell** the restore set `VCPKG_BINARY_SOURCES` in (or set that variable yourself).
- `readwrite` means your build also *writes* any dep the cache was missing back into the dir, so a partial cache
  fills in locally. (Only CI with a token can push back to the shared release.)

### GitHub Actions (the easy CI path)

Drop one step into any consumer workflow. It pulls the cache and exports `VCPKG_BINARY_SOURCES` for every
step after it:

```yaml
- uses: openziti/ziti-sdk-c-binary-cache/restore@main
  with:
    vcpkg-json: native/ZitiNativeApiForDotnetCore/vcpkg.json   # the manifest you build against
    rid: linux-x64                                             # match the runner
# later steps (cmake --preset ..., vcpkg install ...) now get the deps from the cache automatically
```

Inputs: `vcpkg-json` and `rid` (required); `cache-dir`, `repo`, `tag`, `set-binary-sources` (optional). Pin
`@main` until a `v1` tag is cut. Requires PowerShell (preinstalled on all GitHub-hosted runners).

### CI by hand, or any OS with PowerShell 7

`scripts/sync-vcpkg-cache.ps1` does the baseline lookup + pull for you (and is what the action calls):

```powershell
./scripts/sync-vcpkg-cache.ps1 -Action restore -Rid linux-x64 -VcpkgJson path/to/vcpkg.json `
    -CacheDir ./vcpkg-bincache -Repo openziti/ziti-sdk-c-binary-cache
# then set VCPKG_BINARY_SOURCES=clear;files,./vcpkg-bincache,readwrite before building
```

A cache **hit** requires the same three things to match between this producer and your build (vcpkg's
per-package ABI hash covers all of them; any mismatch is a clean miss/rebuild, never a wrong binary):

1. **Same baseline + dep set** - the producer builds ziti-sdk-c's `vcpkg.json`. If your manifest pins a
   different `builtin-baseline`, you pull a different asset (or miss).
2. **Same target / triplet** - the producer uses ziti-sdk-c's own `ci-<target>` presets, which carry the static
   Windows triplets (`x64/x86/arm64-windows-static-md`), `arm64-osx`, `arm64-linux`, etc.
3. **Same runner image / toolchain** - vcpkg's ABI hash includes the compiler. The producer builds on the exact
   images ziti-sdk-c **releases** from: the `openziti/ziti-builder:v3` container for all Linux RIDs,
   `windows-2025` for Windows, and `macos-15` (arm64) / `macos-15-intel` (x64) for macOS.

That third point is the catch for consumers: to share this cache, **you must build in the same env**. A consumer
on bare `ubuntu-latest` or `windows-2022` will miss every Linux/Windows dep. ziti-sdk-csharp's native build is
being converged onto this env (builder container for Linux, `windows-2025`, `macos-15*`, and ziti-sdk-c's
baseline) so it shares the cache; until that lands, csharp builds will miss.

## Status

- Covers all 8 published RIDs: `linux-x64`, `linux-arm`, `linux-arm64`, `osx-x64`, `osx-arm64`, `win-x64`,
  `win-x86`, `win-arm64` (no `ios-arm64` - ziti-sdk-c does not publish it).
- The producer reuses ziti-sdk-c's full release build per leg, so a run takes about as long as a ziti-sdk-c
  release build. A future optimization could stop after CMake configure (which is what actually populates
  `.ci.cache`) instead of completing the compile + package.
- New workflow: give it a manual `workflow_dispatch` run to shake out the container tooling and cross-compile
  legs before trusting the daily cron.
