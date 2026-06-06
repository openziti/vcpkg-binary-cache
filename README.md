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

vcpkg reads a plain local directory via the `files` provider. Restore the tarball into that dir, then point
vcpkg at it:

```
VCPKG_BINARY_SOURCES = "clear;files,<dir>,readwrite"
```

The easy way (CI or local) is `scripts/sync-vcpkg-cache.ps1`, which reads your baseline and pulls the right
asset:

```powershell
./scripts/sync-vcpkg-cache.ps1 -Action restore -Rid linux-x64 -VcpkgJson path/to/vcpkg.json `
    -CacheDir ./vcpkg-bincache -Repo openziti/ziti-sdk-c-binary-cache
```

Or by hand: read `builtin-baseline` from your `vcpkg.json`, then
`curl -L .../native-build-cache/<baseline>-<rid>.tgz | tar -xz -C <dir>`.

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
