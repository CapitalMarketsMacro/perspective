#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo " Perspective Native Build (Linux + vcpkg)"
echo "============================================"
echo

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$REPO_ROOT/dist/perspective"

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
echo "--- Phase 1: Prerequisites ---"
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

echo
echo "--- Phase 2: Building C++ engine + Rust crates (release) ---"
echo

if [ "$USE_VCPKG" = "1" ]; then
    echo "[INFO] Using vcpkg at $VCPKG_ROOT"
fi

cargo build --release -p perspective-client --features omit_metadata
cargo build --release -p perspective-server --no-default-features
cargo build --release -p perspective --features axum-ws

echo
echo "--- Phase 3: Deploying to $DIST_DIR ---"
echo

# Create dist layout
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"/{lib,cpp_cache,example/src}

# Copy Rust source crates (needed for path dependency)
mkdir -p "$DIST_DIR/rust"
cp -r rust/perspective "$DIST_DIR/rust/perspective"
cp -r rust/perspective-client "$DIST_DIR/rust/perspective-client"
cp -r rust/perspective-server "$DIST_DIR/rust/perspective-server"

# Copy pre-built C++ artifacts so downstream builds skip CMake
for d in rust/target/release/build/perspective-server-*/out; do
    if [ -d "$d" ]; then
        echo "[INFO] Caching C++ build artifacts from $d"
        cp -r "$d"/* "$DIST_DIR/cpp_cache/"
        break
    fi
done

# Copy workspace Cargo.toml
cp Cargo.toml "$DIST_DIR/Cargo.toml"

# Create example project
cat > "$DIST_DIR/example/Cargo.toml" << 'CARGO_EOF'
[package]
name = "my-perspective-app"
version = "0.1.0"
edition = "2024"

[features]
default = ["perspective/axum-ws"]

[dependencies]
perspective = { path = "../rust/perspective", default-features = false, features = ["axum-ws"] }
axum = { version = ">=0.8,<0.9", features = ["ws"] }
tokio = { version = "1", features = ["full"] }
tower-http = { version = "0.5", features = ["fs"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }

[workspace]
members = []

# Resolve path dependencies to bundled crates
[patch.crates-io]
perspective = { path = "../rust/perspective" }
perspective-client = { path = "../rust/perspective-client" }
perspective-server = { path = "../rust/perspective-server" }
CARGO_EOF

cat > "$DIST_DIR/example/src/main.rs" << 'RUST_EOF'
use std::net::SocketAddr;

use axum::Router;
use perspective::client::{TableInitOptions, UpdateData};
use perspective::server::Server;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt::init();

    let server = Server::new(None);

    // Load CSV data
    let client = server.new_local_client();
    let csv = "x,y,z\n1,100,a\n2,200,b\n3,300,c\n4,400,d".to_string();
    let mut opts = TableInitOptions::default();
    opts.set_name("my_table");
    client.table(UpdateData::Csv(csv).into(), opts).await?;
    client.close().await;

    // Start WebSocket server — connect <perspective-viewer> to ws://localhost:3000/ws
    let app = Router::new()
        .route("/ws", perspective::axum::websocket_handler())
        .with_state(server);

    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    tracing::info!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
RUST_EOF

# Create env setup script for consumers
cat > "$DIST_DIR/env.sh" << ENV_EOF
#!/usr/bin/env bash
# Source this file before building projects that depend on perspective.
# This reuses pre-built C++ artifacts and skips the CMake rebuild.
#
# Usage: source env.sh

export PSP_CPP_BUILD_DIR="$DIST_DIR/cpp_cache"
export VCPKG_ROOT="${VCPKG_ROOT:-}"
echo "[OK] Perspective environment configured."
echo "     PSP_CPP_BUILD_DIR=\$PSP_CPP_BUILD_DIR"
echo "     VCPKG_ROOT=\$VCPKG_ROOT"
ENV_EOF
chmod +x "$DIST_DIR/env.sh"

echo
echo "============================================"
echo " Build succeeded!"
echo "============================================"
echo
echo "  Deployed to: $DIST_DIR"
echo
echo "  Contents:"
echo "    rust/              - Source crates (path dependency)"
echo "    cpp_cache/         - Pre-built C++ artifacts"
echo "    env.sh             - Source to skip C++ rebuild"
echo "    example/           - Starter project template"
echo
echo "  To use in your project:"
echo "    1. source $DIST_DIR/env.sh"
echo "    2. Add perspective as a path dependency (see example/Cargo.toml)"
echo "    3. cargo build"
echo
echo "  The C++ engine will NOT rebuild as long as PSP_CPP_BUILD_DIR"
echo "  points to the cpp_cache directory."
echo
