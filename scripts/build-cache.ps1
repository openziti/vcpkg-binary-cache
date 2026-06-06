<#
.SYNOPSIS
    Build (or replay) ziti-sdk-c's vcpkg dependencies for one triplet and publish them to the shared binary
    cache release. This is the PRODUCER half: it runs `vcpkg install` against ziti-sdk-c's manifest so the
    deps land in a local files-cache dir, then uploads that dir as a baseline-keyed tarball. Consumers
    (ziti-sdk-c, ziti-sdk-csharp, ziti-tunnel-sdk-c, and devs) only ever PULL, anonymously.

.DESCRIPTION
    Run by .github/workflows/build-cache.yml (daily + manual). Per the design:
      - keyed by the vcpkg `builtin-baseline` (read from ziti-sdk-c's vcpkg.json), so any consumer that shares
        the baseline reuses these deps. A baseline bump just re-caches under a new asset name.
      - build on the SAME runner images consumers use, because vcpkg's ABI hash includes the compiler; a
        different toolchain means a different key and a total miss.

.PARAMETER Rid
    Runtime identifier label for the cache asset, e.g. linux-x64.

.PARAMETER Triplet
    vcpkg triplet to install, e.g. x64-linux. Must match what consumers build (default host triplet per OS).

.PARAMETER ZitiRoot
    Path to a checkout of openziti/ziti-sdk-c (the manifest root: vcpkg.json + vcpkg-configuration.json + overlays).

.PARAMETER CacheDir
    The vcpkg files binary-cache directory to populate and ship.

.PARAMETER Repo
    owner/repo hosting the cache release. Defaults to GITHUB_REPOSITORY.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Rid,
    [Parameter(Mandatory = $true)] [string] $Triplet,
    [Parameter(Mandatory = $true)] [string] $ZitiRoot,
    [string] $CacheDir = (Join-Path $PSScriptRoot '..' 'vcpkg-bincache'),
    [string] $Repo = $env:GITHUB_REPOSITORY
)
$ErrorActionPreference = 'Stop'

$sync = Join-Path $PSScriptRoot 'sync-vcpkg-cache.ps1'
$vcpkgJson = Join-Path $ZitiRoot 'vcpkg.json'
if (-not (Test-Path -LiteralPath $vcpkgJson)) { throw "no vcpkg.json at $vcpkgJson (is -ZitiRoot a ziti-sdk-c checkout?)" }
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

# 1. warm from whatever is already cached for this baseline+rid (incremental: only missing packages rebuild).
& $sync -Action restore -Rid $Rid -VcpkgJson $vcpkgJson -CacheDir $CacheDir -Repo $Repo

# 2. install ziti-sdk-c's deps for this triplet, reading/writing the files cache.
$env:VCPKG_BINARY_SOURCES = "clear;files,$CacheDir,readwrite"
$env:VCPKG_FEATURE_FLAGS = "manifests,binarycaching"
$exe = $IsWindows ? 'vcpkg.exe' : 'vcpkg'
$root = $env:VCPKG_ROOT ? $env:VCPKG_ROOT : $env:VCPKG_INSTALLATION_ROOT
$vcpkg = ($root -and (Test-Path (Join-Path $root $exe))) ? (Join-Path $root $exe) : $exe
Write-Host "vcpkg: $vcpkg  triplet: $Triplet  manifest: $ZitiRoot"
& $vcpkg install --triplet $Triplet "--x-manifest-root=$ZitiRoot" "--x-install-root=$(Join-Path $ZitiRoot 'vcpkg_installed')"
if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed ($LASTEXITCODE)" }

# 3. publish the updated cache (skips upload if unchanged).
& $sync -Action save -Rid $Rid -VcpkgJson $vcpkgJson -CacheDir $CacheDir -Repo $Repo
