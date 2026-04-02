# Building Perspective Native (C++) with Conan

This guide covers building the Perspective C++ engine on **Windows** and **Linux** using [Conan](https://conan.io/) for dependency management, and how to use the built library in your own Rust projects.

For the full JavaScript/Python/WASM development workflow, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Prerequisites

### All Platforms

- **Rust** (nightly) — installed automatically via `rust-toolchain.toml`
- **CMake** 3.29.5 or later
- **Git**
- **Conan** 2.x — see installation below

### Windows

- **Visual Studio 2022** (or Build Tools) with C++ workload
- **MSVC v143** toolset

### Linux

- **GCC 11+** or **Clang 15+**
- **pkg-config**, **autoconf**, **libtool** (for building dependencies)

```bash
# Ubuntu/Debian
sudo apt install build-essential pkg-config autoconf libtool cmake git curl zip unzip tar
```

## Installing Conan

```bash
pip install conan
```

On first use, Conan will auto-detect your compiler and create a default profile. You can verify with:

```bash
conan profile detect
conan profile show
```

The project includes platform-specific profiles in `rust/perspective-server/conan/profiles/` that configure static linking. The build system selects the appropriate profile automatically.

## Build and Deploy

### Windows

```cmd
build_native.bat
```

### Linux

```bash
chmod +x build_native.sh
./build_native.sh
```

The scripts will:
1. Check prerequisites (Rust, CMake, Conan, C++ compiler)
2. Generate protobuf bindings if needed (first-time only)
3. Build the C++ engine and all Rust crates in **release** mode
4. Deploy everything to `dist/perspective/`

The first build takes 10-20 minutes (Conan compiles Arrow, Protobuf, Boost, etc.). Subsequent builds reuse the Conan package cache.

## Deployment Output

After the build, `dist/perspective/` contains:

```
dist/perspective/
  rust/                    # Source crates (used as path dependencies)
    perspective/           # Main facade crate
    perspective-client/    # Client protocol
    perspective-server/    # C++ engine wrapper
  cpp_cache/               # Pre-built C++ static libraries
  example/                 # Starter project template
  env.bat / env.sh         # Environment setup script
```

## Using in Your Rust Project

### Step 1: Set the environment

This tells Cargo to reuse the pre-built C++ artifacts instead of rebuilding from source:

```bash
# Linux
source dist/perspective/env.sh

# Windows
dist\perspective\env.bat
```

This sets `PSP_CPP_BUILD_DIR` to the cached C++ build. **Without this, every `cargo build` would re-run CMake and recompile the C++ engine.**

### Step 2: Create your Cargo.toml

```toml
[package]
name = "my-app"
version = "0.1.0"
edition = "2024"

[dependencies]
perspective = { path = "/path/to/dist/perspective/rust/perspective", features = ["axum-ws"] }
axum = { version = ">=0.8,<0.9", features = ["ws"] }
tokio = { version = "1", features = ["full"] }

[patch.crates-io]
perspective = { path = "/path/to/dist/perspective/rust/perspective" }
perspective-client = { path = "/path/to/dist/perspective/rust/perspective-client" }
perspective-server = { path = "/path/to/dist/perspective/rust/perspective-server" }
```

The `[patch.crates-io]` section is required so that transitive dependencies resolve to the local crates.

### Step 3: Write your application

```rust
use perspective::server::Server;
use perspective::client::{TableInitOptions, UpdateData};
use axum::Router;
use std::net::SocketAddr;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let server = Server::new(None);

    // Load data (CSV, Arrow, JSON supported)
    let client = server.new_local_client();
    let csv = "name,value\nAlpha,100\nBeta,200\nGamma,300".to_string();
    let mut opts = TableInitOptions::default();
    opts.set_name("my_table");
    client.table(UpdateData::Csv(csv).into(), opts).await?;
    client.close().await;

    // Serve over WebSocket for <perspective-viewer> in the browser
    let app = Router::new()
        .route("/ws", perspective::axum::websocket_handler())
        .with_state(server);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await?;
    println!("Listening on http://localhost:3000");
    axum::serve(listener, app).await?;
    Ok(())
}
```

### Step 4: Build

```bash
cargo build --release
```

This compiles only your Rust code. The C++ engine links from the pre-built cache — no CMake, no Conan, no C++ compiler needed.

## Will C++ Dependencies Rebuild?

| Scenario | C++ Rebuilds? |
|----------|--------------|
| `PSP_CPP_BUILD_DIR` set to `cpp_cache/` | **No** — reuses cached `.lib`/`.a` files |
| `PSP_CPP_BUILD_DIR` not set, Conan installed | **Yes** — CMake runs but Conan caches packages |
| Conan not installed | **Yes** — full ExternalProject download + build |
| `PSP_DISABLE_CPP=1` | **Skipped entirely** (link will fail unless libs exist) |

**Recommendation:** Always set `PSP_CPP_BUILD_DIR` when using the deployed package. The `env.bat`/`env.sh` scripts do this for you.

## API Quick Reference

### Core Types

| Type | Description |
|------|-------------|
| `Server` | Owns tables, handles computation |
| `LocalClient` | In-process client (deref to `Client`) |
| `Table` | Data container — update, replace, remove, clear |
| `View` | Query with group_by, filter, sort, expressions |
| `UpdateData` | Input: `Csv`, `Arrow`, `JsonRows`, `JsonColumns`, `Ndjson` |

### Data Flow

```
Server::new() → server.new_local_client() → client.table(data, opts)
                                           → table.view(config)
                                           → view.to_arrow() / to_json_string() / to_csv()
```

### Output Formats

```rust
let arrow_bytes = view.to_arrow(Default::default()).await?;
let json        = view.to_json_string(Default::default()).await?;
let csv         = view.to_csv(Default::default()).await?;
let columns     = view.to_columns_string(Default::default()).await?;
let ndjson      = view.to_ndjson(Default::default()).await?;
```

### View Configuration

```rust
use perspective::client::config::ViewConfigUpdate;

let config = ViewConfigUpdate {
    group_by: Some(vec!["category".into()]),
    columns: Some(vec![Some("price".into()), Some("quantity".into())]),
    sort: vec![Sort("price".into(), SortDir::Desc)],
    filter: vec![Filter("quantity".into(), FilterOp::Gt, Scalar::Float(10.0))],
    ..Default::default()
};
let view = table.view(Some(config)).await?;
```

## Build Without Conan (Fallback)

If Conan is not installed, the build downloads dependencies via CMake `ExternalProject_Add`. This requires internet access during the build but no Conan installation.

## Troubleshooting

### "PSP_CPP_BUILD_DIR" doesn't prevent rebuilds
Ensure the path points to the `cpp_cache/` directory that contains a `build/` subdirectory with `.lib` or `.a` files. The directory must be writable.

### Missing Visual Studio components (Windows)
Install "Desktop development with C++" workload via Visual Studio Installer.

### Slow first build
The first build downloads and compiles all C++ dependencies. Conan caches built packages in `~/.conan2/` so subsequent builds (even in different projects) reuse them.
