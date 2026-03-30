# Building Perspective Native (C++) with vcpkg

This guide covers building the Perspective C++ engine on **Windows** and **Linux** using [vcpkg](https://github.com/microsoft/vcpkg) for dependency management.

For the full JavaScript/Python/WASM development workflow, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Prerequisites

### All Platforms

- **Rust** (nightly) — installed automatically via `rust-toolchain.toml`
- **CMake** 3.29.5 or later
- **Git**
- **vcpkg** — see installation below

### Windows

- **Visual Studio 2022** (or Build Tools) with C++ workload
- **MSVC v143** toolset

### Linux

- **GCC 11+** or **Clang 15+**
- **pkg-config**, **autoconf**, **libtool** (for vcpkg builds)

```bash
# Ubuntu/Debian
sudo apt install build-essential pkg-config autoconf libtool cmake git curl zip unzip tar
```

## Installing vcpkg

If you don't already have vcpkg installed:

```bash
git clone https://github.com/microsoft/vcpkg.git
cd vcpkg
./bootstrap-vcpkg.sh    # Linux/macOS
# or
.\bootstrap-vcpkg.bat   # Windows
```

Set the environment variable:

```bash
# Linux/macOS — add to ~/.bashrc or ~/.zshrc
export VCPKG_ROOT=/path/to/vcpkg

# Windows — set via System Properties or:
setx VCPKG_ROOT "E:\VCPKG\vcpkg"
```

## Quick Start

### Windows

```cmd
build_native.bat
```

### Linux

```bash
chmod +x build_native.sh
./build_native.sh
```

### Manual Build

```bash
export VCPKG_ROOT=/path/to/vcpkg
cargo build -p perspective-server --no-default-features
```

The first build will take 10-20 minutes as vcpkg downloads and compiles all C++ dependencies (Arrow, Protobuf, RE2, Boost, etc.). Subsequent builds use the vcpkg cache and are much faster.

## What Gets Built

The build produces `psp.lib` (Windows) or `libpsp.a` (Linux) — the Perspective C++ engine as a static library, linked into the Rust `perspective-server` crate. All C++ dependencies are statically linked.

### Dependencies resolved by vcpkg

| Library | Version | Purpose |
|---------|---------|---------|
| Apache Arrow | 18.1.0 | Columnar data format, CSV reader |
| Protobuf | ~33.x | Client-server message protocol |
| RE2 | latest | Regular expression engine |
| Boost | ~1.86 | Multi-index containers, UUID, algorithm |
| RapidJSON | latest | JSON parsing |
| date (Hinnant) | 3.x | Date/time utilities |
| tsl-hopscotch-map | latest | High-performance hash map |
| tsl-ordered-map | latest | Insertion-ordered hash map |
| ExprTk | 0.0.3 | Expression parsing engine |

## Build Without vcpkg (Fallback)

If `VCPKG_ROOT` is not set, the build falls back to downloading dependencies via CMake `ExternalProject_Add` (the original behavior). This requires internet access during the build.

```bash
# No VCPKG_ROOT set — uses ExternalProject fallback
cargo build -p perspective-server --no-default-features
```

## Build Options

| Environment Variable | Description |
|---------------------|-------------|
| `VCPKG_ROOT` | Path to vcpkg installation. Enables vcpkg integration. |
| `PSP_BUILD_VERBOSE` | Set to `1` for verbose CMake/MSBuild output |
| `PSP_CPP_BUILD_DIR` | Custom output directory for the C++ build |
| `PSP_DISABLE_CPP` | Skip C++ build entirely |

## Troubleshooting

### vcpkg build fails on first run
vcpkg compiles all dependencies from source. Ensure you have enough disk space (~5 GB) and that your compiler toolchain is properly installed.

### Missing Visual Studio components (Windows)
Install "Desktop development with C++" workload via Visual Studio Installer. Ensure MSVC v143 and Windows SDK are selected.

### Permission errors on Linux
vcpkg may need write access to its install directory. Ensure `$VCPKG_ROOT` is writable by your user.

### Slow first build
The first build downloads and compiles ~90 packages. Subsequent builds reuse the vcpkg binary cache at `$VCPKG_ROOT/buildtrees/`. You can also configure [vcpkg binary caching](https://learn.microsoft.com/en-us/vcpkg/users/binarycaching) for CI.
