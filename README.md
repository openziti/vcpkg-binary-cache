# ziti-sdk-c-binary-cache

A shared [vcpkg](https://vcpkg.io) **binary cache** for [ziti-sdk-c](https://github.com/openziti/ziti-sdk-c)'s
native dependencies (openssl, libuv, protobuf-c, etc.). It exists so ziti-sdk-c, ziti-sdk-csharp,
ziti-tunnel-sdk-c, and individual developers don't each recompile those deps from scratch on every build.

## How it works

This repo is the **producer**. `.github/workflows/build-cache.yml` runs daily (and on manual dispatch),
checks out ziti-sdk-c, runs `vcpkg install` for each triplet, and publishes the resulting binary-cache
directory as a tarball on this repo's own Releases. Everyone else is a **pure anonymous reader** - no token
needed to pull, and no cross-repo push auth needed to produce (the producer writes to its own releases with
the plain `GITHUB_TOKEN`).

- **Keyed by the vcpkg baseline, not the ziti version.** Asset names are `<builtin-baseline>-<rid>.tgz`
  (the baseline is read from ziti-sdk-c's `vcpkg.json`). Any consumer that shares the baseline reuses the
  same deps; a baseline bump just re-caches under a new asset name.
- **One rolling release** (tag `native-build-cache`) holds every baseline's tarballs.
- Pull URL: `https://github.com/openziti/ziti-sdk-c-binary-cache/releases/download/native-build-cache/<baseline>-<rid>.tgz`

## Using it (consumers + developers)

The idea is always the same: download the tarball for your baseline + RID, extract it into a local dir, and
point vcpkg at that dir with `VCPKG_BINARY_SOURCES=clear;files,<dir>,readwrite`. Then build normally - vcpkg
replays the cached deps instead of compiling them. No auth, no login; the release is public.

Pick your RID: `linux-x64`, `osx-arm64`, `osx-x64`, `win-x64`, `win-x86`. The baseline is the
`builtin-baseline` value in the `vcpkg.json` you build against (e.g. ziti-sdk-c's, or ziti-sdk-csharp's
`native/ZitiNativeApiForDotnetCore/vcpkg.json`).

### Linux / macOS (bash)

Needs `jq`, `curl`, `tar` (all standard). Run from your repo so vcpkg picks up the exported variable:

```bash
RID=linux-x64                                   # or osx-arm64 / osx-x64
BASELINE=$(jq -r '."builtin-baseline"' vcpkg.json)
CACHE="$PWD/vcpkg-bincache"; mkdir -p "$CACHE"
URL="https://github.com/openziti/ziti-sdk-c-binary-cache/releases/download/native-build-cache/$BASELINE-$RID.tgz"
curl -fsSL "$URL" | tar -xz -C "$CACHE"
export VCPKG_BINARY_SOURCES="clear;files,$CACHE,readwrite"
# now: cmake --preset ... / vcpkg install ... -- deps come from the cache
```

### Windows (PowerShell)

Windows 10+ ships `curl.exe` and `tar`. PowerShell 7 recommended:

```powershell
$rid = 'win-x64'                                # or win-x86
$baseline = (Get-Content vcpkg.json -Raw | ConvertFrom-Json).'builtin-baseline'
$cache = "$PWD\vcpkg-bincache"; New-Item -ItemType Directory -Force $cache | Out-Null
$url = "https://github.com/openziti/ziti-sdk-c-binary-cache/releases/download/native-build-cache/$baseline-$rid.tgz"
curl.exe -fsSL $url -o "$env:TEMP\vbc.tgz"
tar -xzf "$env:TEMP\vbc.tgz" -C $cache
$env:VCPKG_BINARY_SOURCES = "clear;files,$cache,readwrite"
# now: cmake --preset ... / vcpkg install ...
```

### CI, or any OS with PowerShell 7

`scripts/sync-vcpkg-cache.ps1` does the baseline lookup + pull for you (and is what the consumer repos call):

```powershell
./scripts/sync-vcpkg-cache.ps1 -Action restore -Rid linux-x64 -VcpkgJson path/to/vcpkg.json `
    -CacheDir ./vcpkg-bincache -Repo openziti/ziti-sdk-c-binary-cache
# then set VCPKG_BINARY_SOURCES=clear;files,./vcpkg-bincache,readwrite before building
```

A cache **hit** requires two things to match between this producer and your build:

1. **Same baseline + dep set** - this builds ziti-sdk-c's `vcpkg.json`; if your manifest pins a different
   baseline, you get a miss (a clean rebuild, never a wrong binary - vcpkg's per-package ABI hash guarantees
   that).
2. **Same runner image / toolchain** - vcpkg's ABI hash includes the compiler. The producer builds on the
   images consumers use (`ubuntu-latest`, `windows-2022`, `macos-14`/`macos-13`); a different toolchain is a
   total miss, not a corruption.

## Status (v1)

- Covers the desktop RIDs: `linux-x64`, `win-x64`, `win-x86`, `osx-arm64`, `osx-x64`.
- **Follow-ups:** cross-compiled RIDs (`linux-arm`, `linux-arm64`, `ios-arm64`) need their toolchains wired
  into the matrix; and the producer should track whichever runner images the consumers actually use.
- The producer workflow is new and wants a manual `workflow_dispatch` run to shake out the `vcpkg install`
  specifics (overlay ports, the runner's vcpkg vs the baseline) before the daily cron is trusted.
