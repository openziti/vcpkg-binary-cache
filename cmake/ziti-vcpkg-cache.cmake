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
#   ZITI_VCPKG_CACHE_DIR     extract location (default <binary>/vcpkg-bincache)
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
if(NOT DEFINED ZITI_VCPKG_CACHE_DIR)
  set(ZITI_VCPKG_CACHE_DIR "${CMAKE_BINARY_DIR}/vcpkg-bincache")
endif()

# --- baseline (the cache key) ---
if(NOT EXISTS "${ZITI_VCPKG_CACHE_VCPKG_JSON}")
  message(STATUS "ziti-vcpkg-cache: no vcpkg.json at ${ZITI_VCPKG_CACHE_VCPKG_JSON}; skipping")
  return()
endif()
file(READ "${ZITI_VCPKG_CACHE_VCPKG_JSON}" _zvc_json)
string(JSON _zvc_baseline ERROR_VARIABLE _zvc_err GET "${_zvc_json}" "builtin-baseline")
if(_zvc_err OR NOT _zvc_baseline)
  message(STATUS "ziti-vcpkg-cache: no builtin-baseline in manifest; skipping")
  return()
endif()

# --- RID: explicit override, else auto-detect the host (OS booleans + uname/PROCESSOR_ARCHITECTURE are all
#     available before project(), unlike CMAKE_HOST_SYSTEM_PROCESSOR) ---
if(NOT DEFINED ZITI_VCPKG_CACHE_RID)
  if(CMAKE_HOST_WIN32)
    set(_zvc_os win)
    if(DEFINED ENV{PROCESSOR_ARCHITEW6432})
      set(_zvc_raw "$ENV{PROCESSOR_ARCHITEW6432}")
    else()
      set(_zvc_raw "$ENV{PROCESSOR_ARCHITECTURE}")
    endif()
  elseif(CMAKE_HOST_APPLE)
    set(_zvc_os osx)
    execute_process(COMMAND uname -m OUTPUT_VARIABLE _zvc_raw OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  elseif(CMAKE_HOST_UNIX)
    set(_zvc_os linux)
    execute_process(COMMAND uname -m OUTPUT_VARIABLE _zvc_raw OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  endif()
  if(_zvc_raw MATCHES "^(x86_64|AMD64|amd64)$")
    set(_zvc_cpu x64)
  elseif(_zvc_raw MATCHES "^(aarch64|arm64|ARM64)$")
    set(_zvc_cpu arm64)
  elseif(_zvc_raw MATCHES "^(armv7l|armv6l|arm)$")
    set(_zvc_cpu arm)
  elseif(_zvc_raw MATCHES "^(x86|i686|i386)$")
    set(_zvc_cpu x86)
  endif()
  if(_zvc_os AND _zvc_cpu)
    set(ZITI_VCPKG_CACHE_RID "${_zvc_os}-${_zvc_cpu}")
  endif()
endif()
if(NOT DEFINED ZITI_VCPKG_CACHE_RID)
  message(STATUS "ziti-vcpkg-cache: could not detect a RID (set -DZITI_VCPKG_CACHE_RID=...); skipping")
  return()
endif()

# --- download + extract once per build tree (sentinel only written on a hit, so a miss retries next configure) ---
set(_zvc_tag "${ZITI_VCPKG_CACHE_PREFIX}-${_zvc_baseline}")
set(_zvc_url "https://github.com/${ZITI_VCPKG_CACHE_REPO}/releases/download/${_zvc_tag}/${ZITI_VCPKG_CACHE_RID}.tgz")
file(MAKE_DIRECTORY "${ZITI_VCPKG_CACHE_DIR}")
if(NOT EXISTS "${ZITI_VCPKG_CACHE_DIR}/.ziti-fetched")
  set(_zvc_tgz "${CMAKE_BINARY_DIR}/ziti-vcpkg-cache.tgz")
  message(STATUS "ziti-vcpkg-cache: ${ZITI_VCPKG_CACHE_PREFIX} ${ZITI_VCPKG_CACHE_RID} @ ${_zvc_baseline}")
  message(STATUS "ziti-vcpkg-cache: fetching ${_zvc_url}")
  file(DOWNLOAD "${_zvc_url}" "${_zvc_tgz}" STATUS _zvc_status)
  list(GET _zvc_status 0 _zvc_code)
  if(_zvc_code EQUAL 0)
    file(ARCHIVE_EXTRACT INPUT "${_zvc_tgz}" DESTINATION "${ZITI_VCPKG_CACHE_DIR}")
    file(WRITE "${ZITI_VCPKG_CACHE_DIR}/.ziti-fetched" "${_zvc_tag}/${ZITI_VCPKG_CACHE_RID}\n")
    file(REMOVE "${_zvc_tgz}")
    message(STATUS "ziti-vcpkg-cache: restored into ${ZITI_VCPKG_CACHE_DIR}")
  else()
    list(GET _zvc_status 1 _zvc_msg)
    message(STATUS "ziti-vcpkg-cache: cache miss (${_zvc_msg}); vcpkg will build these deps from source")
  endif()
endif()

# Point vcpkg at the cache for the manifest install that fires at project(). readwrite so a partial cache fills
# in locally as vcpkg builds anything that was missing.
set(ENV{VCPKG_BINARY_SOURCES} "clear;files,${ZITI_VCPKG_CACHE_DIR},readwrite")
message(STATUS "ziti-vcpkg-cache: VCPKG_BINARY_SOURCES -> clear;files,${ZITI_VCPKG_CACHE_DIR},readwrite")
