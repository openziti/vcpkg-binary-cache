# shellcheck shell=bash
# Pull the prebuilt ziti-sdk-c vcpkg binary cache for THIS machine and point vcpkg at it by setting
# VCPKG_BINARY_SOURCES. Auto-detects your RID (uname) and reads the baseline from a vcpkg.json, so you just run:
#
#   SOURCE it (so the export lands in your current shell - this is the point):
#     source scripts/restore-cache.sh                      # baseline from ./vcpkg.json, RID auto-detected
#     source scripts/restore-cache.sh path/to/vcpkg.json
#
#   No clone, one line:
#     source <(curl -fsSL https://raw.githubusercontent.com/openziti/ziti-sdk-c-binary-cache/main/scripts/restore-cache.sh)
#
#   Or capture the export without sourcing:
#     eval "$(bash scripts/restore-cache.sh)"
#
# Overrides via env: RID, ZITI_CACHE_DIR, ZITI_CACHE_REPO, ZITI_CACHE_TAG.
# Needs: bash or zsh, curl, tar (jq optional - falls back to grep for the baseline).

__ziti_restore_cache() {
    local vcpkg_json="${1:-./vcpkg.json}"
    local repo="${ZITI_CACHE_REPO:-openziti/ziti-sdk-c-binary-cache}"
    local tag="${ZITI_CACHE_TAG:-}"   # one release per baseline; defaults to the baseline below
    local cache_dir="${ZITI_CACHE_DIR:-$PWD/vcpkg-bincache}"
    local rid="${RID:-}"

    if [ -z "$rid" ]; then
        local os arch
        os="$(uname -s)"; arch="$(uname -m)"
        case "$os" in
            Linux)  case "$arch" in
                        x86_64|amd64)  rid=linux-x64;;
                        aarch64|arm64) rid=linux-arm64;;
                        armv7l|armv6l|arm*) rid=linux-arm;;
                    esac;;
            Darwin) case "$arch" in
                        arm64)  rid=osx-arm64;;
                        x86_64) rid=osx-x64;;
                    esac;;
        esac
    fi
    if [ -z "$rid" ]; then
        echo "[ziti-cache] could not detect a RID for $(uname -s)/$(uname -m); set RID=... and retry" >&2
        return 1
    fi
    echo "[ziti-cache] 1/4 detecting RID ......... $rid" >&2

    echo "[ziti-cache] 2/4 detecting baseline .... reading 'builtin-baseline' from $vcpkg_json" >&2
    if [ ! -f "$vcpkg_json" ]; then
        echo "[ziti-cache] vcpkg.json not found at '$vcpkg_json' (pass its path as the first arg)" >&2
        return 1
    fi
    local baseline=""
    if command -v jq >/dev/null 2>&1; then
        baseline="$(jq -r '."builtin-baseline" // empty' "$vcpkg_json" 2>/dev/null)"
    fi
    if [ -z "$baseline" ]; then
        baseline="$(grep -oE '"builtin-baseline"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' "$vcpkg_json" \
                    | grep -oE '[0-9a-fA-F]{40}' | head -n1)"
    fi
    if [ -z "$baseline" ]; then
        echo "[ziti-cache] no builtin-baseline found in '$vcpkg_json'" >&2
        return 1
    fi
    echo "[ziti-cache]                            $baseline" >&2

    [ -z "$tag" ] && tag="baseline-$baseline"   # GitHub forbids a tag that is exactly 40/64 hex chars
    local url="https://github.com/$repo/releases/download/$tag/$rid.tgz"
    if ! mkdir -p "$cache_dir"; then return 1; fi
    echo "[ziti-cache] 3/4 downloading cache ..... $url" >&2
    local tmp; tmp="$(mktemp)" || return 1
    if curl -fsSL "$url" -o "$tmp"; then
        echo "[ziti-cache]     extracting cache to  $cache_dir" >&2
        if ! tar -xzf "$tmp" -C "$cache_dir"; then
            echo "[ziti-cache]     ERROR: extract failed" >&2; rm -f "$tmp"; return 1
        fi
    else
        echo "[ziti-cache]     MISS: no cached asset for this baseline+rid. Not an error: vcpkg will build" >&2
        echo "[ziti-cache]           these deps from source and write them into $cache_dir itself." >&2
    fi
    rm -f "$tmp"

    local val="clear;files,$cache_dir,readwrite"
    if [ "${__ZITI_SOURCED:-0}" = "1" ]; then
        export VCPKG_BINARY_SOURCES="$val"
        echo "[ziti-cache] 4/4 pointing vcpkg here . VCPKG_BINARY_SOURCES=$val" >&2
        echo "[ziti-cache] done. Build as usual (cmake --preset .../vcpkg install) - deps come from the cache." >&2
    else
        echo "export VCPKG_BINARY_SOURCES='$val'"
        echo "[ziti-cache] 4/4 NOT sourced, so the export won't stick. Re-run as:" >&2
        echo "[ziti-cache]     source ${BASH_SOURCE:-<this-script>}   (or: eval \"\$(bash <this-script>)\")" >&2
    fi
}

# Detect whether we were sourced (return only succeeds in a sourced context), run, then leave the caller's
# shell clean: no leftover functions or vars.
if (return 0 2>/dev/null); then __ZITI_SOURCED=1; else __ZITI_SOURCED=0; fi
__ziti_restore_cache "$@"
__ZITI_RC=$?
unset -f __ziti_restore_cache 2>/dev/null
if [ "$__ZITI_SOURCED" = "1" ]; then
    unset __ZITI_SOURCED
    rc=$__ZITI_RC; unset __ZITI_RC
    return $rc
else
    unset __ZITI_SOURCED
    rc=$__ZITI_RC; unset __ZITI_RC
    exit $rc
fi
