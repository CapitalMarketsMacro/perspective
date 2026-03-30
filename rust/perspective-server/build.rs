// ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
// ┃ ██████ ██████ ██████       █      █      █      █      █ █▄  ▀███ █       ┃
// ┃ ▄▄▄▄▄█ █▄▄▄▄▄ ▄▄▄▄▄█  ▀▀▀▀▀█▀▀▀▀▀ █ ▀▀▀▀▀█ ████████▌▐███ ███▄  ▀█ █ ▀▀▀▀▀ ┃
// ┃ █▀▀▀▀▀ █▀▀▀▀▀ █▀██▀▀ ▄▄▄▄▄ █ ▄▄▄▄▄█ ▄▄▄▄▄█ ████████▌▐███ █████▄   █ ▄▄▄▄▄ ┃
// ┃ █      ██████ █  ▀█▄       █ ██████      █      ███▌▐███ ███████▄ █       ┃
// ┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
// ┃ Copyright (c) 2017, the Perspective Authors.                              ┃
// ┃ ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌ ┃
// ┃ This file is part of the Perspective library, distributed under the terms ┃
// ┃ of the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). ┃
// ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

use std::fs;
use std::path::{Path, PathBuf};

use cmake::Config;
use protobuf_src::protoc;
use shlex::Shlex;

fn main() -> Result<(), std::io::Error> {
    if std::env::var("DOCS_RS").is_ok() {
        return Ok(());
    }

    if std::option_env!("PSP_DISABLE_CPP").is_none()
        && std::env::var("CARGO_FEATURE_DISABLE_CPP").is_err()
        && let Some(artifact_dir) = cmake_build()?
    {
        cmake_link_deps(&artifact_dir)?;
    }

    Ok(())
}

/// Returns the vcpkg root path from the VCPKG_ROOT environment variable.
fn vcpkg_root() -> Option<PathBuf> {
    std::env::var("VCPKG_ROOT").ok().map(PathBuf::from)
}

/// Returns the appropriate vcpkg triplet for the current target platform.
fn vcpkg_triplet() -> &'static str {
    if cfg!(target_os = "windows") {
        "x64-windows-static-perspective"
    } else if cfg!(target_os = "linux") {
        "x64-linux-static"
    } else if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            "arm64-osx"
        } else {
            "x64-osx"
        }
    } else {
        panic!("Unsupported target OS for vcpkg triplet selection");
    }
}

fn cmake_build() -> Result<Option<PathBuf>, std::io::Error> {
    let mut dst = Config::new("cpp/perspective");
    if let Some(cpp_build_dir) = std::option_env!("PSP_CPP_BUILD_DIR") {
        std::fs::create_dir_all(cpp_build_dir)?;
        dst.out_dir(cpp_build_dir);
    }

    let profile = std::env::var("PROFILE").unwrap();
    dst.always_configure(true);
    dst.define("CMAKE_BUILD_TYPE", profile.as_str());
    dst.define("ARROW_BUILD_EXAMPLES", "OFF");
    dst.define("RAPIDJSON_BUILD_EXAMPLES", "OFF");
    dst.define("ARROW_CXX_FLAGS_DEBUG", "-Wno-error");
    dst.define(
        "PSP_PROTOC_PATH",
        protoc()
            .parent()
            .expect("protoc() returned root path or empty string"),
    );
    dst.define("CMAKE_COLOR_DIAGNOSTICS", "ON");
    dst.define(
        "PSP_PROTO_PATH",
        std::env::var("DEP_PERSPECTIVE_CLIENT_PROTO_PATH").unwrap(),
    );

    dst.env(
        "DEP_PERSPECTIVE_CLIENT_PROTO_PATH",
        std::env::var("DEP_PERSPECTIVE_CLIENT_PROTO_PATH").unwrap(),
    );

    let is_wasm = std::env::var("TARGET")
        .unwrap_or_default()
        .contains("wasm32");

    // vcpkg integration for native (non-WASM) builds
    if !is_wasm {
        if let Some(root) = vcpkg_root() {
            let toolchain_file = root.join("scripts").join("buildsystems").join("vcpkg.cmake");
            if toolchain_file.exists() {
                let triplet = vcpkg_triplet();
                let manifest_dir = std::fs::canonicalize(".")
                    .expect("Failed to canonicalize current directory");
                let overlay_triplets = std::fs::canonicalize("cmake/triplets")
                    .expect("Failed to canonicalize triplets directory");

                println!("cargo:warning=Using vcpkg at {} with triplet {}", root.display(), triplet);

                // For macOS cross-compilation, the existing Darwin toolchain file
                // is set as CMAKE_TOOLCHAIN_FILE. In that case, chainload vcpkg.
                if cfg!(target_os = "macos") && std::env::var("PSP_ARCH").is_ok() {
                    dst.define("VCPKG_CHAINLOAD_TOOLCHAIN_FILE", &toolchain_file);
                } else {
                    dst.define("CMAKE_TOOLCHAIN_FILE", &toolchain_file);
                }

                dst.define("VCPKG_TARGET_TRIPLET", triplet);
                dst.define("VCPKG_MANIFEST_DIR", &manifest_dir);
                dst.define("VCPKG_OVERLAY_TRIPLETS", &overlay_triplets);
            } else {
                println!(
                    "cargo:warning=VCPKG_ROOT is set but vcpkg.cmake not found at {}",
                    toolchain_file.display()
                );
            }
        } else {
            println!("cargo:warning=VCPKG_ROOT not set; falling back to ExternalProject dependency resolution");
        }
    }

    if cfg!(target_os = "macos") {
        // Set CMAKE_OSX_ARCHITECTURES et al. for Mac builds.  Arrow does not forward on
        // CMAKE_OSX_ARCHITECTURES but it does forward on a CMAKE_TOOLCHAIN_FILE. In
        // Conda builds, the environment sets `CMAKE_ARGS` up with various
        // toolchain arguments. This block may need to be patched out or
        // adjusted for Conda.
        let toolchain_file = match std::env::var("PSP_ARCH").as_deref() {
            Ok("x86_64") => Some("./cmake/toolchains/darwin-x86_64.cmake"),
            Ok("aarch64") => Some("./cmake/toolchains/darwin-arm64.cmake"),
            Err(std::env::VarError::NotPresent) => None,
            arch @ Ok(_) | arch @ Err(_) => {
                panic!("Unknown PSP_ARCH value: {arch:?}")
            },
        };

        if let Some(path) = toolchain_file {
            // When vcpkg is active, the vcpkg toolchain is already set as
            // CMAKE_TOOLCHAIN_FILE and the Darwin toolchain is chainloaded
            // via VCPKG_CHAINLOAD_TOOLCHAIN_FILE (set above). When vcpkg is
            // not active, set the Darwin toolchain directly.
            if vcpkg_root().is_none() || is_wasm {
                dst.define(
                    "CMAKE_TOOLCHAIN_FILE",
                    std::fs::canonicalize(path).expect("Failed to canonicalize toolchain file."),
                );
            }
        }
    }

    if is_wasm {
        dst.define("PSP_WASM_BUILD", "1");
    } else {
        dst.define("PSP_WASM_BUILD", "0");
    }

    if std::env::var("CARGO_FEATURE_PYTHON").is_ok() {
        dst.define("CMAKE_POSITION_INDEPENDENT_CODE", "ON");
        dst.define("PSP_PYTHON_BUILD", "1");
    }

    if std::env::var("CARGO_FEATURE_EXTERNAL_CPP").is_err() {
        dst.env("PSP_DISABLE_CLANGD", "1");
    }

    // WASM Exceptions don't work with the prebuilt Pyodide distribution.
    // It must be rebuilt with WASM exceptions enabled
    if std::env::var("CARGO_FEATURE_WASM_EXCEPTIONS").is_ok() {
        dst.define("PSP_WASM_EXCEPTIONS", "1");
    } else {
        dst.define("PSP_WASM_EXCEPTIONS", "0");
    }

    if !cfg!(windows) {
        dst.build_arg(format!("-j{}", num_cpus::get()));
    }

    // Conda sets CMAKE_ARGS for e.g. cross-compiling toolchain in the environment -
    // normally they are passed directly to a cmake invocation in the recipe,
    // but our conda recipe doesn't directly invoke cmake
    if let Ok(cmake_args) = std::env::var("CMAKE_ARGS") {
        println!("cargo:warning=Setting CMAKE_ARGS from environment {cmake_args:?}");
        for arg in Shlex::new(&cmake_args) {
            dst.configure_arg(arg);
        }
    }

    // Build only the psp target (not "install" which may not exist)
    dst.build_target("psp");

    println!("cargo:warning=Building cmake {profile}");
    if std::env::var("PSP_BUILD_VERBOSE").unwrap_or_default() != "" {
        // checks non-empty env var
        dst.very_verbose(true);
    }

    let artifact_dir = dst.build();
    Ok(Some(artifact_dir))
}

fn cmake_link_deps(cmake_build_dir: &Path) -> Result<(), std::io::Error> {
    let build_dir = cmake_build_dir.join("build");
    println!(
        "cargo:rustc-link-search=native={}",
        build_dir.display()
    );

    println!("cargo:rustc-link-lib=static=psp");

    let is_wasm = std::env::var("TARGET")
        .unwrap_or_default()
        .contains("wasm32");

    let mut linked = std::collections::HashSet::new();

    if !is_wasm && vcpkg_root().is_some() {
        // vcpkg path: link psp + protos from cmake build, then vcpkg libs from
        // the single correct triplet release lib dir. Do NOT recursively walk
        // vcpkg_installed/ — it contains debug/ and host triplet dirs that would
        // cause massive duplication and trigger rustc archive size bugs.
        let triplet = vcpkg_triplet();
        let vcpkg_lib_dir = build_dir
            .join("vcpkg_installed")
            .join(triplet)
            .join("lib");

        // Link protos from its build dir
        let protos_dir = build_dir.join("protos-build");
        link_archives_flat(&protos_dir, &mut linked)?;

        // Link all vcpkg release libs (non-recursive, single directory)
        if vcpkg_lib_dir.exists() {
            println!(
                "cargo:warning=Adding vcpkg lib dir: {}",
                vcpkg_lib_dir.display()
            );
            link_archives_flat(&vcpkg_lib_dir, &mut linked)?;
        }
    } else {
        // ExternalProject path: recursive walk is fine since there's no
        // vcpkg_installed directory with duplicate triplets.
        link_cmake_static_archives(cmake_build_dir, &mut linked)?;
    }

    println!("cargo:rerun-if-changed=cpp/perspective");
    println!("cargo:rerun-if-changed=vcpkg.json");
    Ok(())
}

/// Link all static archives in a single directory (non-recursive).
fn link_archives_flat(dir: &Path, linked: &mut std::collections::HashSet<String>) -> Result<(), std::io::Error> {
    if !dir.is_dir() {
        return Ok(());
    }

    // On Windows with MSVC/Visual Studio generator, release libs may be in a
    // MinSizeRel/ or Release/ subdirectory. Check for those too.
    let dirs_to_scan: Vec<PathBuf> = if cfg!(windows) {
        let mut dirs = vec![dir.to_path_buf()];
        for sub in &["MinSizeRel", "Release", "RelWithDebInfo"] {
            let p = dir.join(sub);
            if p.is_dir() {
                dirs.push(p);
            }
        }
        dirs
    } else {
        vec![dir.to_path_buf()]
    };

    for scan_dir in &dirs_to_scan {
        println!("cargo:rustc-link-search=native={}", scan_dir.display());
        for entry in fs::read_dir(scan_dir)? {
            let path = entry?.path();
            if path.is_dir() {
                continue;
            }
            if let Some(name) = archive_lib_name(&path) {
                if linked.insert(name.clone()) {
                    println!("cargo:rustc-link-lib=static={name}");
                }
            }
        }
    }
    Ok(())
}

/// Walk the cmake output path and emit link instructions for all archives.
/// Used only for the ExternalProject (non-vcpkg) path.
fn link_cmake_static_archives(dir: &Path, linked: &mut std::collections::HashSet<String>) -> Result<(), std::io::Error> {
    if !dir.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            // Skip vcpkg_installed if it somehow exists in this path
            let name = path.file_name().map(|n| n.to_string_lossy());
            if name.as_deref() == Some("vcpkg_installed") {
                continue;
            }
            link_cmake_static_archives(&path, linked)?;
        } else if let Some(name) = archive_lib_name(&path) {
            if linked.insert(name.clone()) {
                println!("cargo:rustc-link-search=native={}", dir.display());
                println!("cargo:rustc-link-lib=static={name}");
            }
        }
    }
    Ok(())
}

/// Extract the library name from an archive file path, or None if not an archive.
fn archive_lib_name(path: &Path) -> Option<String> {
    let ext = path.extension()?.to_string_lossy();
    let stem = path.file_stem()?.to_string_lossy();

    let is_archive = (cfg!(windows) && ext == "lib" && stem != "perspective")
        || (!cfg!(windows) && ext == "a");

    if !is_archive {
        return None;
    }

    let name = if cfg!(windows) {
        stem.to_string()
    } else {
        // Strip "lib" prefix: libfoo.a -> foo
        stem.strip_prefix("lib").unwrap_or(&stem).to_string()
    };
    Some(name)
}
