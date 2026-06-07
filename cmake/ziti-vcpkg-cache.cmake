# ziti-vcpkg-cache.cmake
#
# Transparently restore the prebuilt OpenZiti vcpkg binary cache for THIS machine, so dependencies
# (openssl, libuv, protobuf-c, ...) are replayed instead of compiled. Pure CMake: no curl/tar/jq needed.
#
# It must run BEFORE project(), because vcpkg installs the manifest's dependencies when its toolchain file is
# loaded during the first project() call. Include it like this:
#
#   set(ZITI_VCPKG_CACHE_PREFIX csdk)        # which project's cache: csdk (default) | tsdk | ...
#   include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/ziti-vcpkg-cache.cmake)
#   project(my_project C)
#
# ...or fetch this module itself first so consumers vendor nothing (see the README "CMake does it for you").
#
# Knobs (set as variables before include, or -D... on the command line):
#   ZITI_VCPKG_CACHE         ON/OFF  master switch (default ON; also off if VCPKG_BINARY_SOURCES already set)
#   ZITI_VCPKG_CACHE_PREFIX  csdk|tsdk|...           which project's cache (default csdk)
#   ZITI_VCPKG_CACHE_RID     linux-x64, windows-x64-mingw, ...  asset name (default: auto-detected host RID)
#   ZITI_VCPKG_CACHE_VCPKG_JSON  manifest to read the baseline from (default <source>/vcpkg.json)
#   ZITI_VCPKG_CACHE_DIR     shared extract location (default: per-user dir - %LOCALAPPDATA%/ziti-vcpkg-bincache,
#                            or $XDG_CACHE_HOME / ~/.cache/ziti-vcpkg-bincache - so all worktrees share it; also
#                            reads the ZITI_VCPKG_CACHE_DIR env var)
#   ZITI_VCPKG_CACHE_REPO    owner/repo hosting the releases (default openziti/vcpkg-binary-cache)

option(ZITI_VCPKG_CACHE "Restore the prebuilt OpenZiti vcpkg binary cache" ON)
if(NOT ZITI_VCPKG_CACHE)
  return()
endif()

# Don't clobber an explicit binary-cache setup (team feed, CI cache, a manual export).
if(DEFINED ENV{VCPKG_BINARY_SOURCES})
  message(STATUS "ziti-vcpkg-cache: VCPKG_BINARY_SOURCES already set; leaving it as-is")
  return()
endif()

if(NOT DEFINED ZITI_VCPKG_CACHE_PREFIX)
  set(ZITI_VCPKG_CACHE_PREFIX "csdk")
endif()
if(NOT DEFINED ZITI_VCPKG_CACHE_REPO)
  set(ZITI_VCPKG_CACHE_REPO "openziti/vcpkg-binary-cache")
endif()
if(NOT DEFINED ZITI_VCPKG_CACHE_VCPKG_JSON)
  set(ZITI_VCPKG_CACHE_VCPKG_JSON "${CMAKE_CURRENT_SOURCE_DIR}/vcpkg.json")
endif()
# Default to a per-USER, per-MACHINE dir (not the build tree) so every worktree/branch on this machine shares
# one local cache: pulled-from-local first, fetched on demand only for baselines/RIDs not seen yet. vcpkg's
# files cache is content-addressed, so csdk + tsdk + many baselines coexist in this one dir with no collisions.
if(NOT DEFINED ZITI_VCPKG_CACHE_DIR)
  if(DEFINED ENV{ZITI_VCPKG_CACHE_DIR})
    set(ZITI_VCPKG_CACHE_DIR "$ENV{ZITI_VCPKG_CACHE_DIR}")
  elseif(CMAKE_HOST_WIN32 AND DEFINED ENV{LOCALAPPDATA})
    set(ZITI_VCPKG_CACHE_DIR "$ENV{LOCALAPPDATA}/ziti-vcpkg-bincache")
  elseif(DEFINED ENV{XDG_CACHE_HOME})
    set(ZITI_VCPKG_CACHE_DIR "$ENV{XDG_CACHE_HOME}/ziti-vcpkg-bincache")
  elseif(DEFINED ENV{HOME})
    set(ZITI_VCPKG_CACHE_DIR "$ENV{HOME}/.cache/ziti-vcpkg-bincache")
  else()
    set(ZITI_VCPKG_CACHE_DIR "${CMAKE_BINARY_DIR}/vcpkg-bincache")
  endif()
endif()

# --- baseline (the cache key) ---
if(NOT EXISTS "${ZITI_VCPKG_CACHE_VCPKG_JSON}")
  message(STATUS "ziti-vcpkg-cache: no vcpkg.json at ${ZITI_VCPKG_CACHE_VCPKG_JSON}; skipping")
  return()
endif()
file(READ "${ZITI_VCPKG_CACHE_VCPKG_JSON}" _ziti_vcpkg_cache_json)
string(JSON _ziti_vcpkg_cache_baseline ERROR_VARIABLE _ziti_vcpkg_cache_err GET "${_ziti_vcpkg_cache_json}" "builtin-baseline")
if(_ziti_vcpkg_cache_err OR NOT _ziti_vcpkg_cache_baseline)
  message(STATUS "ziti-vcpkg-cache: no builtin-baseline in manifest; skipping")
  return()
endif()

# --- RID: explicit override, else auto-detect the host (OS booleans + uname/PROCESSOR_ARCHITECTURE are all
#     available before project(), unlike CMAKE_HOST_SYSTEM_PROCESSOR) ---
if(NOT DEFINED ZITI_VCPKG_CACHE_RID)
  if(CMAKE_HOST_WIN32)
    set(_ziti_vcpkg_cache_os win)
    if(DEFINED ENV{PROCESSOR_ARCHITEW6432})
      set(_ziti_vcpkg_cache_raw "$ENV{PROCESSOR_ARCHITEW6432}")
    else()
      set(_ziti_vcpkg_cache_raw "$ENV{PROCESSOR_ARCHITECTURE}")
    endif()
  elseif(CMAKE_HOST_APPLE)
    set(_ziti_vcpkg_cache_os osx)
    execute_process(COMMAND uname -m OUTPUT_VARIABLE _ziti_vcpkg_cache_raw OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  elseif(CMAKE_HOST_UNIX)
    set(_ziti_vcpkg_cache_os linux)
    execute_process(COMMAND uname -m OUTPUT_VARIABLE _ziti_vcpkg_cache_raw OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  endif()
  if(_ziti_vcpkg_cache_raw MATCHES "^(x86_64|AMD64|amd64)$")
    set(_ziti_vcpkg_cache_cpu x64)
  elseif(_ziti_vcpkg_cache_raw MATCHES "^(aarch64|arm64|ARM64)$")
    set(_ziti_vcpkg_cache_cpu arm64)
  elseif(_ziti_vcpkg_cache_raw MATCHES "^(armv7l|armv6l|arm)$")
    set(_ziti_vcpkg_cache_cpu arm)
  elseif(_ziti_vcpkg_cache_raw MATCHES "^(x86|i686|i386)$")
    set(_ziti_vcpkg_cache_cpu x86)
  endif()
  if(_ziti_vcpkg_cache_os AND _ziti_vcpkg_cache_cpu)
    set(ZITI_VCPKG_CACHE_RID "${_ziti_vcpkg_cache_os}-${_ziti_vcpkg_cache_cpu}")
  endif()
endif()
if(NOT DEFINED ZITI_VCPKG_CACHE_RID)
  message(STATUS "ziti-vcpkg-cache: could not detect a RID (set -DZITI_VCPKG_CACHE_RID=...); skipping")
  return()
endif()

# --- local-first, fetch-on-demand. A per-(prefix,baseline,rid) marker records what this machine has already
#     pulled into the shared dir, so a second worktree/branch reuses it with no network. A miss writes no marker,
#     so it retries next configure (e.g. once the release is published). ---
set(_ziti_vcpkg_cache_tag "${ZITI_VCPKG_CACHE_PREFIX}-${_ziti_vcpkg_cache_baseline}")
set(_ziti_vcpkg_cache_url "https://github.com/${ZITI_VCPKG_CACHE_REPO}/releases/download/${_ziti_vcpkg_cache_tag}/${ZITI_VCPKG_CACHE_RID}.tgz")
set(_ziti_vcpkg_cache_marker "${ZITI_VCPKG_CACHE_DIR}/.fetched/${_ziti_vcpkg_cache_tag}-${ZITI_VCPKG_CACHE_RID}")
file(MAKE_DIRECTORY "${ZITI_VCPKG_CACHE_DIR}")
message(STATUS "ziti-vcpkg-cache: ${ZITI_VCPKG_CACHE_PREFIX} ${ZITI_VCPKG_CACHE_RID} @ ${_ziti_vcpkg_cache_baseline}")
message(STATUS "ziti-vcpkg-cache: shared cache dir ${ZITI_VCPKG_CACHE_DIR}")
if(EXISTS "${_ziti_vcpkg_cache_marker}")
  message(STATUS "ziti-vcpkg-cache: LOCAL HIT - already pulled ${_ziti_vcpkg_cache_tag}/${ZITI_VCPKG_CACHE_RID}; no download")
else()
  set(_ziti_vcpkg_cache_tgz "${CMAKE_BINARY_DIR}/ziti-vcpkg-cache.tgz")
  message(STATUS "ziti-vcpkg-cache: fetching ${_ziti_vcpkg_cache_url}")
  file(DOWNLOAD "${_ziti_vcpkg_cache_url}" "${_ziti_vcpkg_cache_tgz}" STATUS _ziti_vcpkg_cache_status)
  list(GET _ziti_vcpkg_cache_status 0 _ziti_vcpkg_cache_code)
  if(_ziti_vcpkg_cache_code EQUAL 0)
    file(ARCHIVE_EXTRACT INPUT "${_ziti_vcpkg_cache_tgz}" DESTINATION "${ZITI_VCPKG_CACHE_DIR}")
    file(MAKE_DIRECTORY "${ZITI_VCPKG_CACHE_DIR}/.fetched")
    file(WRITE "${_ziti_vcpkg_cache_marker}" "${_ziti_vcpkg_cache_url}\n")
    file(REMOVE "${_ziti_vcpkg_cache_tgz}")
    message(STATUS "ziti-vcpkg-cache: FETCHED + extracted into shared cache")
  else()
    list(GET _ziti_vcpkg_cache_status 1 _ziti_vcpkg_cache_msg)
    message(STATUS "ziti-vcpkg-cache: MISS (${_ziti_vcpkg_cache_msg}); vcpkg will build these deps from source")
  endif()
endif()

# Point vcpkg at the cache for the manifest install that fires at project(). readwrite so a partial cache fills
# in locally as vcpkg builds anything that was missing.
set(ENV{VCPKG_BINARY_SOURCES} "clear;files,${ZITI_VCPKG_CACHE_DIR},readwrite")
message(STATUS "ziti-vcpkg-cache: VCPKG_BINARY_SOURCES -> clear;files,${ZITI_VCPKG_CACHE_DIR},readwrite")
