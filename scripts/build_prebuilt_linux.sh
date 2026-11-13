#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build_prebuilt_linux.sh - Build shaderc from source on Linux x64
#
# Produces the prebuilt/linux/ layout this repo's release workflow publishes and
# the Neurus build consumes (prebuilt/linux/<name>/lib/...).
#
# Only shaderc is built here. qtadvanceddocking is a Qt library and the Linux
# Neurus build is headless (NEURUS_BUILD_UI=OFF), so no Linux build links it;
# shipping a Qt archive for a platform with no Qt toolchain would only be dead
# weight in the release.
#
# The build is glibc-version sensitive: a shaderc built on a newer distribution
# will not load on an older one. The release job therefore builds this on the
# oldest supported image (ubuntu-22.04).
#
# Usage:
#   ./scripts/build_prebuilt_linux.sh [--clean]
#
# Run chmod +x first:
#   chmod +x scripts/build_prebuilt_linux.sh
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}  OK: $1${NC}"; }
warn()  { echo -e "${YELLOW}  WARN: $1${NC}"; }
fail()  { echo -e "${RED}${BOLD}  FAIL: $1${NC}" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo -e "${BOLD}=== Neurus Linux x64 Library Builder ===${NC}"
echo "  Project root: ${PROJECT_ROOT}"

CLEAN=0
for arg in "$@"; do
    case "${arg}" in
        --clean) CLEAN=1 ;;
        -h|--help)
            echo "Usage: $0 [--clean]"
            echo ""
            echo "  --clean   Remove previous build artifacts before building"
            exit 0
            ;;
        *) fail "Unknown argument: ${arg}" ;;
    esac
done

if [[ ${CLEAN} -eq 1 ]]; then
    step "Cleaning previous build artifacts"
    for dir in "${PROJECT_ROOT}/build/_shaderc_linux" "${PROJECT_ROOT}/prebuilt/linux"; do
        if [[ -d "${dir}" ]]; then
            echo "  Removing ${dir}"
            rm -rf "${dir}"
        fi
    done
    ok "Clean complete"
fi

SHADERC_OUT="${PROJECT_ROOT}/prebuilt/linux/shaderc/lib"
mkdir -p "${SHADERC_OUT}"

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        fail "Required command '$1' not found. Please install it first."
    fi
}

step "Preflight checks"
require_cmd cmake
require_cmd ninja
require_cmd git
require_cmd python3
ok "All required commands found"

# =============================
#  shaderc
# =============================
step "shaderc: Initializing submodule"
(
    cd "${PROJECT_ROOT}"
    git submodule update --init src/shaderc
) || fail "Failed to initialize shaderc submodule"
ok "shaderc submodule initialized"

# glslang, SPIRV-Tools and SPIRV-Headers are not submodules; shaderc pins them by
# revision in DEPS and this script resolves them.
step "shaderc: Syncing dependencies (glslang, spirv-tools, spirv-headers)"
(
    cd "${PROJECT_ROOT}/src/shaderc"
    python3 utils/git-sync-deps
) || fail "Failed to sync shaderc dependencies (git-sync-deps)"
ok "shaderc dependencies synced"

step "shaderc: CMake configure"
SHADERC_BUILD="${PROJECT_ROOT}/build/_shaderc_linux"
cmake -S "${PROJECT_ROOT}/src/shaderc" -B "${SHADERC_BUILD}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_ENABLE_EXAMPLES=OFF \
    -DSHADERC_SKIP_INSTALL=OFF \
    -DCMAKE_INSTALL_PREFIX="${SHADERC_BUILD}/install" \
    -DSHADERC_ENABLE_HLSL=OFF \
    -DENABLE_OPT=OFF \
|| fail "shaderc CMake configure failed"
ok "shaderc configured"

step "shaderc: Building"
cmake --build "${SHADERC_BUILD}" --config Release || fail "shaderc build failed"
ok "shaderc built"

step "shaderc: Installing"
cmake --install "${SHADERC_BUILD}" || fail "shaderc install failed"
ok "shaderc installed"

step "shaderc: Copying shared libraries to prebuilt/linux/shaderc/lib/"
INSTALL_LIB="${SHADERC_BUILD}/install/lib"
[[ -d "${INSTALL_LIB}" ]] || fail "shaderc install lib directory not found at ${INSTALL_LIB}"

# The release tarball must carry the real file plus its SONAME links, and the
# unversioned libshaderc_shared.so the consumer imports.
cp -a "${INSTALL_LIB}"/libshaderc_shared*.so* "${SHADERC_OUT}/" \
|| fail "Failed to copy shaderc shared libraries"

if [[ -e "${SHADERC_OUT}/libshaderc_shared.so" ]]; then
    ok "libshaderc_shared.so present"
else
    warn "libshaderc_shared.so missing - linking it to the versioned library"
    VERSIONED=$(find "${SHADERC_OUT}" -name 'libshaderc_shared.so.*' -not -type l | head -1)
    [[ -n "${VERSIONED}" ]] || fail "No versioned libshaderc_shared.so found"
    ln -sf "$(basename "${VERSIONED}")" "${SHADERC_OUT}/libshaderc_shared.so"
    ok "Created symlink libshaderc_shared.so -> $(basename "${VERSIONED}")"
fi

# The consumer only needs the shared object; record what produced it so a
# release can be traced back to a compiler and libc.
step "shaderc: Writing build stamp"
{
    echo "cxx_standard=20"
    echo "compiler=$(c++ --version | head -1)"
    echo "glibc=$(ldd --version | head -1)"
} > "${PROJECT_ROOT}/prebuilt/linux/shaderc/build_info.txt"
ok "build stamp written"

echo ""
echo -e "${GREEN}${BOLD}Linux prebuilt complete${NC}"
echo "  shaderc: ${SHADERC_OUT}"
echo ""
echo "  Package with: tar -czf linux-x64.tar.gz -C prebuilt linux"
