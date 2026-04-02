#!/usr/bin/env bash
# ============================================================
#  Perspective - detect prerequisites, set up Conan, and build
#
#  Usage:
#    ./setup_and_build.sh            Build (always cleans CMake cache)
#    ./setup_and_build.sh --clean    Full clean (CMake cache + Cargo + Conan output)
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONAN_DIR="$REPO_ROOT/rust/perspective-server"
PROFILES_DIR="$CONAN_DIR/conan/profiles"
BUILD_DIR="$REPO_ROOT/rust/target/release/build"
CONAN_OUTPUT="$CONAN_DIR/conan_output"
FULL_CLEAN=0

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --clean|-c) FULL_CLEAN=1 ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "  ${CYAN}[INFO]${NC} $*"; }

echo
echo "========================================================"
echo "  Perspective — Setup & Build"
echo "========================================================"
echo

# ------------------------------------------------------------------
# 1. Detect platform
# ------------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux*)  PLATFORM="linux"  ;;
    Darwin*) PLATFORM="macos"  ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *)       fail "Unsupported OS: $OS" ;;
esac

case "$ARCH" in
    x86_64|amd64) ARCH_TAG="x64"   ;;
    aarch64|arm64) ARCH_TAG="arm64" ;;
    *)             fail "Unsupported architecture: $ARCH" ;;
esac

PROFILE_NAME="${PLATFORM}-${ARCH_TAG}-static"
# Windows arm64 falls back to x64 (cross-compile)
if [[ "$PLATFORM" == "windows" && "$ARCH_TAG" == "arm64" ]]; then
    PROFILE_NAME="windows-x64-static"
fi

info "Platform: $PLATFORM / $ARCH  →  Conan profile: $PROFILE_NAME"
echo

# ------------------------------------------------------------------
# 1.5. Clean
# ------------------------------------------------------------------
echo "--- Cleaning build artifacts ---"
echo

# Always clean CMake cache to avoid stale toolset/config errors
for d in "$BUILD_DIR"/perspective-server-*/out/build; do
    if [ -f "$d/CMakeCache.txt" ]; then
        echo "  [CLEAN] Removing CMake cache: $d/CMakeCache.txt"
        rm -f "$d/CMakeCache.txt"
    fi
    if [ -d "$d/CMakeFiles" ]; then
        echo "  [CLEAN] Removing CMakeFiles: $d/CMakeFiles"
        rm -rf "$d/CMakeFiles"
    fi
done

if [ "$FULL_CLEAN" -eq 1 ]; then
    echo "  [CLEAN] Full clean requested (--clean)"
    echo

    # Remove all perspective-server build dirs
    for d in "$BUILD_DIR"/perspective-server-*/; do
        if [ -d "$d" ]; then
            echo "  [CLEAN] Removing $d"
            rm -rf "$d"
        fi
    done

    # Remove Conan output
    if [ -d "$CONAN_OUTPUT" ]; then
        echo "  [CLEAN] Removing Conan output: $CONAN_OUTPUT"
        rm -rf "$CONAN_OUTPUT"
    fi

    # Remove compiled perspective crate artifacts
    for f in "$REPO_ROOT"/rust/target/release/libperspective_server.{rlib,d}; do
        if [ -f "$f" ]; then
            echo "  [CLEAN] Removing $f"
            rm -f "$f"
        fi
    done

    echo
    echo "  [OK]   Full clean done"
fi

echo

# ------------------------------------------------------------------
# 2. Check prerequisites
# ------------------------------------------------------------------
echo "--- Checking prerequisites ---"
echo

MISSING=()

# Rust
if command -v rustc &>/dev/null; then
    ok "$(rustc --version)"
else
    MISSING+=("rust")
    warn "rustc not found — install from https://rustup.rs"
fi

# CMake
if command -v cmake &>/dev/null; then
    ok "$(cmake --version | head -1)"
else
    MISSING+=("cmake")
    warn "cmake not found — install from https://cmake.org/download/"
fi

# C++ compiler
CXX_FOUND=0
if command -v g++ &>/dev/null; then
    ok "$(g++ --version | head -1)"
    CXX_FOUND=1
elif command -v clang++ &>/dev/null; then
    ok "$(clang++ --version | head -1)"
    CXX_FOUND=1
elif command -v cl &>/dev/null; then
    ok "MSVC cl.exe found"
    CXX_FOUND=1
fi
if [[ "$CXX_FOUND" -eq 0 ]]; then
    MISSING+=("c++ compiler")
    warn "No C++ compiler found (g++, clang++, or cl.exe)"
fi

# Python / pip (needed to install Conan)
if command -v python3 &>/dev/null; then
    ok "$(python3 --version)"
    PIP_CMD="python3 -m pip"
elif command -v python &>/dev/null; then
    ok "$(python --version)"
    PIP_CMD="python -m pip"
else
    MISSING+=("python")
    warn "python not found — needed to install Conan (pip install conan)"
    PIP_CMD=""
fi

echo
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Missing prerequisites: ${MISSING[*]}${NC}"
    echo "Please install them and re-run this script."
    echo
    # Don't exit yet if only Conan is missing — we can install it below.
    # But if Rust/CMake/C++ compiler is missing, we can't build.
    for m in "${MISSING[@]}"; do
        if [[ "$m" != "python" ]]; then
            if [[ "$m" == "rust" || "$m" == "cmake" || "$m" == "c++ compiler" ]]; then
                fail "Cannot continue without: ${MISSING[*]}"
            fi
        fi
    done
fi

# ------------------------------------------------------------------
# 3. Install / detect Conan
# ------------------------------------------------------------------
echo "--- Setting up Conan ---"
echo

CONAN_INSTALLED=0
if command -v conan &>/dev/null; then
    CONAN_VER="$(conan --version 2>/dev/null || true)"
    ok "Conan already installed: $CONAN_VER"
    CONAN_INSTALLED=1
else
    info "Conan not found — attempting to install via pip..."
    if [[ -z "$PIP_CMD" ]]; then
        warn "pip not available, cannot auto-install Conan."
        warn "Install manually: pip install conan"
        warn "Build will fall back to ExternalProject (slower, downloads sources)."
    else
        $PIP_CMD install --user conan
        # Refresh PATH for newly installed conan
        export PATH="$HOME/.local/bin:$PATH"
        if command -v conan &>/dev/null; then
            ok "Conan installed: $(conan --version)"
            CONAN_INSTALLED=1
        else
            warn "Conan installed but not in PATH. Add ~/.local/bin to your PATH."
            warn "Build will fall back to ExternalProject."
        fi
    fi
fi

echo

# ------------------------------------------------------------------
# 4. Initialize Conan profile (first-time setup)
# ------------------------------------------------------------------
if [[ "$CONAN_INSTALLED" -eq 1 ]]; then
    echo "--- Configuring Conan profile ---"
    echo

    # Detect default profile if none exists yet
    if ! conan profile show &>/dev/null 2>&1; then
        info "No default Conan profile detected — running auto-detect..."
        conan profile detect
        ok "Default profile created"
    else
        ok "Default Conan profile exists"
    fi

    # Show which project profile will be used
    PROFILE_FILE="$PROFILES_DIR/$PROFILE_NAME"
    if [[ -f "$PROFILE_FILE" ]]; then
        ok "Project profile: $PROFILE_FILE"
        echo
        echo "  Profile contents:"
        sed 's/^/    /' "$PROFILE_FILE"
        echo
    else
        warn "Project profile $PROFILE_NAME not found in $PROFILES_DIR"
        info "Will use Conan's default profile"
    fi

    # ------------------------------------------------------------------
    # 5. Pre-install Conan dependencies
    # ------------------------------------------------------------------
    echo "--- Installing C++ dependencies via Conan ---"
    echo
    info "This may take a while on first run (building Arrow, Boost, etc.)"
    info "Subsequent runs reuse the Conan cache at ~/.conan2/"
    echo

    CONAN_OUTPUT="$CONAN_DIR/conan_output"
    mkdir -p "$CONAN_OUTPUT"

    CONAN_ARGS=(
        install "$CONAN_DIR"
        --output-folder "$CONAN_OUTPUT"
        --build=missing
    )

    if [[ -f "$PROFILE_FILE" ]]; then
        CONAN_ARGS+=(--profile "$PROFILE_FILE")
    fi

    if conan "${CONAN_ARGS[@]}"; then
        ok "Conan dependencies installed"
        echo
        info "Generated files in $CONAN_OUTPUT:"
        ls -1 "$CONAN_OUTPUT"/*.cmake 2>/dev/null | head -10 | sed 's/^/    /'
        echo
    else
        warn "Conan install failed — build will fall back to ExternalProject"
        echo
    fi
fi

# ------------------------------------------------------------------
# 6. Run the main build
# ------------------------------------------------------------------
echo "--- Building Perspective ---"
echo

if [[ -f "$REPO_ROOT/build_native.sh" ]]; then
    info "Running build_native.sh ..."
    echo
    exec bash "$REPO_ROOT/build_native.sh"
else
    fail "build_native.sh not found at $REPO_ROOT"
fi
