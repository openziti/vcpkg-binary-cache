<#
.SYNOPSIS
    Pull the prebuilt ziti-sdk-c vcpkg binary cache for THIS machine and set $env:VCPKG_BINARY_SOURCES.

.DESCRIPTION
    Auto-detects your RID (processor architecture) and reads the vcpkg baseline from a vcpkg.json, downloads the
    matching <baseline>-<rid>.tgz from the public cache release, extracts it, and points vcpkg at it. DOT-SOURCE
    it so the env var lands in your session (a child process cannot set the parent's environment):

      . .\scripts\restore-cache.ps1                          # baseline from .\vcpkg.json, RID auto-detected
      . .\scripts\restore-cache.ps1 -VcpkgJson path\to\vcpkg.json

    No clone, one line (Invoke-Expression runs in the current scope, so the export sticks):

      iex (irm https://raw.githubusercontent.com/openziti/vcpkg-binary-cache/main/scripts/restore-cache.ps1)

    Needs: PowerShell 5.1+ (or 7), plus curl/tar (bundled on Windows 10+). A miss (no asset) is fine - vcpkg just
    builds those deps and populates the dir.
#>
[CmdletBinding()]
param(
    [string] $VcpkgJson = './vcpkg.json',
    [string] $Rid,
    [string] $CacheDir,
    [string] $Repo = 'openziti/vcpkg-binary-cache',
    [string] $Prefix = 'csdk',   # which project's cache: csdk, tsdk, ... (use -Prefix tsdk for ziti-tunnel-sdk-c)
    [string] $Tag                # defaults to <Prefix>-<baseline> below
)
$ErrorActionPreference = 'Stop'

if (-not $Rid) {
    $a = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $Rid = switch ($a) { 'AMD64' { 'win-x64' } 'x86' { 'win-x86' } 'ARM64' { 'win-arm64' } default { '' } }
}
if (-not $Rid) { Write-Error "ziti-cache: could not detect a RID (PROCESSOR_ARCHITECTURE=$env:PROCESSOR_ARCHITECTURE); pass -Rid"; return }
Write-Host "[ziti-cache] 1/4 detecting RID ......... $Rid"

Write-Host "[ziti-cache] 2/4 detecting baseline .... reading 'builtin-baseline' from $VcpkgJson"
if (-not (Test-Path -LiteralPath $VcpkgJson)) { Write-Error "ziti-cache: vcpkg.json not found at '$VcpkgJson' (pass -VcpkgJson)"; return }
$baseline = (Get-Content -LiteralPath $VcpkgJson -Raw | ConvertFrom-Json).'builtin-baseline'
if (-not $baseline) { Write-Error "ziti-cache: no builtin-baseline in '$VcpkgJson'"; return }
Write-Host "[ziti-cache]                            $baseline"
if (-not $Tag) { $Tag = "$Prefix-$baseline" }   # one release per project+baseline

if (-not $CacheDir) { $CacheDir = Join-Path $PWD 'vcpkg-bincache' }
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$CacheDir = (Resolve-Path -LiteralPath $CacheDir).Path

$url = "https://github.com/$Repo/releases/download/$Tag/$Rid.tgz"
Write-Host "[ziti-cache] 3/4 downloading cache ..... $url"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "ziti-vbc-$Rid.tgz"
try {
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Write-Host "[ziti-cache]     extracting cache to  $CacheDir"
    & tar -xzf $tmp -C $CacheDir
    if ($LASTEXITCODE -ne 0) { throw "tar extract failed ($LASTEXITCODE)" }
}
catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
        Write-Host "[ziti-cache]     MISS: no cached asset for this baseline+rid. Not an error: vcpkg will"
        Write-Host "[ziti-cache]           build these deps from source and write them into $CacheDir itself."
    }
    else { throw }
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

$env:VCPKG_BINARY_SOURCES = "clear;files,$CacheDir,readwrite"
Write-Host "[ziti-cache] 4/4 pointing vcpkg here . VCPKG_BINARY_SOURCES=$env:VCPKG_BINARY_SOURCES"
Write-Host "[ziti-cache] done. Build as usual (cmake --preset ... / vcpkg install) - deps come from the cache."
