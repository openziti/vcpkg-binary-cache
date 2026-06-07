<#
.SYNOPSIS
    Sync the vcpkg binary cache for one RID to/from a single rolling GitHub Release, keyed by the vcpkg baseline.

.DESCRIPTION
    The cache is the vcpkg binary-cache directory (the prebuilt openssl/protobuf/etc archives vcpkg replays so it
    does not recompile). What those archives contain is pinned by the vcpkg baseline, so we key the cache by the
    baseline (read from native/ZitiNativeApiForDotnetCore/vcpkg.json `builtin-baseline`), NOT the ziti-sdk-c
    version. Every ziti version that shares a baseline reuses the same cache. There is one prerelease PER
    baseline (the release tag IS the baseline), holding one `<rid>.tgz` per RID. Pull is anonymous (plain HTTPS
    download), so any repo or developer can grab `<rid>.tgz` from their baseline's release, drop it in their
    files cache, and build fast. Push needs a token with contents:write (CI only).

    No nuget, no mono: vcpkg only ever reads a local directory via VCPKG_BINARY_SOURCES=files,<dir>. This script
    just moves that directory in and out of the release.

    Actions:
      ensure-release  Create this baseline's prerelease if missing (idempotent). Run once before the matrix so
                      the parallel save legs do not race the create.
      restore         Anonymously download <rid>.tgz from the baseline's release and extract into -CacheDir. A
                      miss (404) is fine.
      save            Hash -CacheDir's contents; if it differs from the sidecar on the release, tar it up and
                      upload <rid>.tgz plus its .sha256 (clobbering). Unchanged = skip.

.PARAMETER Action
    ensure-release | restore | save.

.PARAMETER Rid
    Runtime identifier, e.g. win-x64 (required for restore/save).

.PARAMETER Baseline
    The vcpkg builtin-baseline that keys the cache. Defaults to the `builtin-baseline` read from -VcpkgJson.

.PARAMETER CacheDir
    The vcpkg files binary-cache directory (the dir named in VCPKG_BINARY_SOURCES=files,<dir>).

.PARAMETER Repo
    owner/repo that hosts the release. Defaults to GITHUB_REPOSITORY.

.PARAMETER VcpkgJson
    Path to the vcpkg manifest to read the baseline from. Defaults to native/ZitiNativeApiForDotnetCore/vcpkg.json.

.PARAMETER Tag
    Release tag. Defaults to the vcpkg baseline (one release per baseline). Override only for testing.

.PARAMETER Token
    Token with contents:write, for ensure-release/save. Defaults to GH_TOKEN then GITHUB_TOKEN. Not needed for
    restore.

.EXAMPLE
    ./sync-vcpkg-cache.ps1 -Action restore -Rid win-x64 -CacheDir ./vcpkg-bincache
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateSet('ensure-release', 'restore', 'save')] [string] $Action,
    [string] $Rid,
    [string] $Baseline,
    [string] $CacheDir,
    [string] $Repo = $env:GITHUB_REPOSITORY,
    [string] $VcpkgJson = (Join-Path $PSScriptRoot '..' 'ziti-sdk-c' 'vcpkg.json'),
    [string] $Tag,
    [string] $Token = ($env:GH_TOKEN ? $env:GH_TOKEN : $env:GITHUB_TOKEN)
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Repo)) { throw "Repo is required (-Repo or GITHUB_REPOSITORY)." }

# The cache key is the vcpkg BASELINE (+ RID/triplet), not the ziti-sdk-c version: the prebuilt deps are
# pinned by the vcpkg baseline, so every ziti version that shares a baseline reuses the same cache, and a
# baseline change naturally lands in a different release. Read the baseline from the manifest unless passed in.
if ([string]::IsNullOrWhiteSpace($Baseline)) {
    if (-not (Test-Path -LiteralPath $VcpkgJson)) { throw "vcpkg.json not found at $VcpkgJson (pass -Baseline or -VcpkgJson)." }
    $Baseline = (Get-Content -LiteralPath $VcpkgJson -Raw | ConvertFrom-Json).'builtin-baseline'
    if ([string]::IsNullOrWhiteSpace($Baseline)) { throw "no builtin-baseline in $VcpkgJson (pass -Baseline)." }
}
# One release per vcpkg baseline: tag is `baseline-<hash>` (GitHub rejects a tag that is exactly 40/64 hex
# chars, so the bare baseline cannot be the tag), assets are just <rid>.tgz. A baseline bump lands in its own
# release; pruning a stale baseline is just deleting that release.
if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = "baseline-$Baseline" }
$asset = "$Rid.tgz"
$shaAsset = "$asset.sha256"
$downloadBase = "https://github.com/$Repo/releases/download/$Tag"

# Anonymous GET of a release asset. Returns the response content (string) or $null on 404.
function Get-AssetText {
    param([string] $Name)
    try {
        # GitHub serves release assets as octet-stream, so .Content comes back as byte[]; decode to text.
        $content = (Invoke-WebRequest -Uri "$downloadBase/$Name" -UseBasicParsing).Content
        if ($content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($content) }
        return $content
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

# Deterministic hash of the cache dir contents: sorted relative paths plus each file's SHA256, hashed together.
# We hash the contents, not the .tgz, because tar embeds mtimes so identical inputs would differ byte for byte.
function Get-DirHash {
    param([string] $Dir)
    $files = Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName
    if (-not $files) { return $null }
    $full = (Resolve-Path -LiteralPath $Dir).Path
    $sb = [System.Text.StringBuilder]::new()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($full.Length).TrimStart('\', '/').Replace('\', '/')
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLower()
        [void]$sb.Append($rel).Append("`t").Append($h).Append("`n")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
}

function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $GhArgs)
    if (-not [string]::IsNullOrWhiteSpace($Token)) { $env:GH_TOKEN = $Token }
    & gh @GhArgs
    if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed with exit code $LASTEXITCODE." }
}

switch ($Action) {
    'ensure-release' {
        & gh release view $Tag --repo $Repo *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Release '$Tag' already exists."
        }
        else {
            Write-Host "Creating prerelease for baseline '$Tag' ..."
            Invoke-Gh release create $Tag --repo $Repo --prerelease --title "vcpkg baseline $Baseline" `
                --notes 'vcpkg binary cache tarballs for this baseline, one <rid>.tgz per RID. Anonymous pull, fast native builds. Auto-managed, do not edit.'
        }
    }

    'restore' {
        if (-not $Rid -or -not $CacheDir) { throw "restore needs -Rid and -CacheDir." }
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) $asset
        Write-Host "Restoring $asset from $downloadBase ..."
        try {
            Invoke-WebRequest -Uri "$downloadBase/$asset" -OutFile $tmp -UseBasicParsing
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                Write-Host "Cache miss: $asset not on release '$Tag'. Build will populate it."
                return
            }
            throw
        }
        & tar -xzf $tmp -C $CacheDir
        if ($LASTEXITCODE -ne 0) { throw "tar extract failed with exit code $LASTEXITCODE." }
        Remove-Item -LiteralPath $tmp -Force
        Write-Host "Restored cache into $CacheDir."
    }

    'save' {
        if (-not $Rid -or -not $CacheDir) { throw "save needs -Rid and -CacheDir." }
        if (-not (Test-Path -LiteralPath $CacheDir)) {
            Write-Host "No cache dir at $CacheDir; nothing to save."
            return
        }
        $hash = Get-DirHash -Dir $CacheDir
        if (-not $hash) {
            Write-Host "Cache dir $CacheDir is empty; nothing to save."
            return
        }
        $remote = (Get-AssetText -Name $shaAsset)
        if ($remote -and $remote.Trim() -eq $hash) {
            Write-Host "Cache unchanged ($hash); skipping upload of $asset."
            return
        }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) $asset
        $tmpSha = Join-Path ([System.IO.Path]::GetTempPath()) $shaAsset
        Write-Host "Cache changed; packing $asset ..."
        & tar -czf $tmp -C $CacheDir .
        if ($LASTEXITCODE -ne 0) { throw "tar create failed with exit code $LASTEXITCODE." }
        $hash | Out-File -FilePath $tmpSha -Encoding ascii -NoNewline
        Write-Host "Uploading $asset and $shaAsset to release '$Tag' ..."
        Invoke-Gh release upload $Tag --repo $Repo --clobber $tmp $tmpSha
        Remove-Item -LiteralPath $tmp, $tmpSha -Force
        Write-Host "Saved $asset ($hash)."
    }
}
