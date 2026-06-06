# ziti-sdk-c-binary-cache

A shared [vcpkg](https://vcpkg.io) **binary cache** for [ziti-sdk-c](https://github.com/openziti/ziti-sdk-c)'s
native dependencies (openssl, libuv, protobuf-c, etc.). It exists so ziti-sdk-c, ziti-sdk-csharp,
ziti-tunnel-sdk-c, and individual developers don't each recompile those deps from scratch on every build.

## How it works

This repo is the **producer**. `.github/workflows/build-cache.yml` runs daily (and on manual dispatch). To
guarantee the cached deps have the exact ABI ziti-sdk-c ships, it does not hand-roll `vcpkg install`: it checks
out ziti-sdk-c and runs **ziti-sdk-c's own release build action** (`./.github/actions/build`) for each published
target, on the same runners and builder containers ziti-sdk-c releases from. That action already writes a vcpkg
`files` binary cache to `.ci.cache`; the producer harvests that directory and publishes it as a tarball on this
repo's own Releases. Because it reuses ziti-sdk-c's build verbatim, there is zero preset/triplet/toolchain drift.
Everyone else is a **pure anonymous reader** - no token needed to pull, and no cross-repo push auth needed to
produce (the producer writes to its own releases with the plain `GITHUB_TOKEN`).

- **Keyed by the vcpkg baseline, not the ziti version.** Asset names are `<builtin-baseline>-<rid>.tgz`
  (the baseline is read from ziti-sdk-c's `vcpkg.json`). Any consumer that shares the baseline reuses the
  same deps; a baseline bump just re-caches under a new asset name.
- **One rolling release** (tag `native-build-cache`) holds every baseline's tarballs.
- Pull URL: `https://github.com/openziti/ziti-sdk-c-binary-cache/releases/download/native-build-cache/<baseline>-<rid>.tgz`

## Using it (consumers + developers)

The idea is always the same: download the tarball for your baseline + RID, extract it into a local dir, and
point vcpkg at that dir with `VCPKG_BINARY_SOURCES=clear;files,<dir>,readwrite`. Then build normally - vcpkg
replays the cached deps instead of compiling them. No auth, no login; the release is public.

Pick your RID: `linux-x64`, `linux-arm`, `linux-arm64`, `osx-arm64`, `osx-x64`, `win-x64`, `win-x86`,
`win-arm64`. The baseline is the `builtin-baseline` value in the `vcpkg.json` you build against (e.g.
ziti-sdk-c's, or ziti-sdk-csharp's `native/ZitiNativeApiForDotnetCore/vcpkg.json`).

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
