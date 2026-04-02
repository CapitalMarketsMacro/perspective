#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo " Perspective Native Build (Linux + Conan)"
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

# Check for Conan
USE_CONAN=0
if ! command -v conan &>/dev/null; then
    echo "[WARN] conan not found in PATH."
    echo "       The build will fall back to downloading dependencies via ExternalProject."
    echo "       To use Conan, install it: pip install conan"
else
    echo "[OK] $(conan --version)"
    USE_CONAN=1
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

if [ "$USE_CONAN" = "1" ]; then
    echo "[INFO] Conan is available and will be used for C++ dependencies"
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

# Copy only the needed pre-built .a/.lib files (not entire build tree)
for d in rust/target/release/build/perspective-server-*/out/build; do
    if [ -d "$d" ]; then
        echo "[INFO] Caching C++ build artifacts from $d"
        mkdir -p "$DIST_DIR/cpp_cache/build"

        # psp static lib
        find "$d" -maxdepth 1 -name "libpsp.a" -exec cp {} "$DIST_DIR/cpp_cache/build/" \;

        # protos static lib
        if [ -d "$d/protos-build" ]; then
            mkdir -p "$DIST_DIR/cpp_cache/build/protos-build"
            find "$d/protos-build" -maxdepth 1 -name "libprotos.a" -exec cp {} "$DIST_DIR/cpp_cache/build/protos-build/" \;
        fi

        # Conan-installed libs are in the Conan cache and linked via CMake.
        # For the dist cache, we copy the static archives that CMake linked.
        conan_output="$d/../conan_output"
        if [ -d "$conan_output" ]; then
            # Parse lib dirs from Conan-generated cmake files and copy archives
            for cmake_file in "$conan_output"/*.cmake; do
                [ -f "$cmake_file" ] || continue
                grep -oP '(?<=")[^"]+/lib(?=")' "$cmake_file" 2>/dev/null | sort -u | while read -r libdir; do
                    if [ -d "$libdir" ]; then
                        mkdir -p "$DIST_DIR/cpp_cache/conan_libs"
                        cp "$libdir"/*.a "$DIST_DIR/cpp_cache/conan_libs/" 2>/dev/null || true
                    fi
                done
            done
            echo "  [CONAN] Copied release libs"
        fi

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
echo "[OK] Perspective environment configured."
echo "     PSP_CPP_BUILD_DIR=\$PSP_CPP_BUILD_DIR"
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
