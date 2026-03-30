#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo " Perspective Native Build (Linux + vcpkg)"
echo "============================================"
echo

# Check for Rust
if ! command -v rustc &>/dev/null; then
    echo "[ERROR] rustc not found in PATH."
    echo "Install Rust from https://rustup.rs"
    exit 1
fi
echo "[OK] $(rustc --version)"

# Check for CMake
if ! command -v cmake &>/dev/null; then
    echo "[ERROR] cmake not found in PATH."
    echo "Install CMake 3.29.5+ from https://cmake.org/download/"
    exit 1
fi
echo "[OK] $(cmake --version | head -1)"

# Check for C++ compiler
if command -v g++ &>/dev/null; then
    echo "[OK] $(g++ --version | head -1)"
elif command -v clang++ &>/dev/null; then
    echo "[OK] $(clang++ --version | head -1)"
else
    echo "[ERROR] No C++ compiler found. Install gcc or clang."
    exit 1
fi

# Check for vcpkg
USE_VCPKG=0
if [ -z "${VCPKG_ROOT:-}" ]; then
    echo "[WARN] VCPKG_ROOT is not set."
    echo "       The build will fall back to downloading dependencies via ExternalProject."
    echo "       To use vcpkg, set VCPKG_ROOT to your vcpkg installation directory."
else
    if [ ! -f "$VCPKG_ROOT/vcpkg" ]; then
        echo "[WARN] vcpkg binary not found at $VCPKG_ROOT"
        echo "       Run ./bootstrap-vcpkg.sh in your vcpkg directory first."
        echo "       Falling back to ExternalProject."
    else
        echo "[OK] vcpkg found at $VCPKG_ROOT"
        USE_VCPKG=1
    fi
fi

echo
echo "--- Starting build ---"
echo

# Generate placeholder for expression_gen.md if missing
mkdir -p rust/perspective-client/docs
if [ ! -f rust/perspective-client/docs/expression_gen.md ]; then
    touch rust/perspective-client/docs/expression_gen.md
    echo "[INFO] Created placeholder expression_gen.md"
fi

# Generate proto.rs if missing
if [ ! -f rust/perspective-client/src/rust/proto.rs ]; then
    echo "[INFO] Generating protobuf bindings (first-time setup)..."
    cargo build -p perspective-client --features generate-proto,protobuf-src,omit_metadata
    echo "[OK] Protobuf bindings generated."
    echo
fi

# Build perspective-server
echo "[INFO] Building perspective-server (C++ engine)..."
if [ "$USE_VCPKG" = "1" ]; then
    echo "[INFO] Using vcpkg at $VCPKG_ROOT"
fi
echo

cargo build -p perspective-server --no-default-features

echo
echo "============================================"
echo " Build succeeded!"
echo "============================================"
