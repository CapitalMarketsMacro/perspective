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
use std::process::Command;

use cmake::Config;
use shlex::Shlex;

/// Find the protoc binary. Checks in order:
/// 1. Conan output directory (version-matched protoc from Conan)
/// 2. PROTOC env var
/// 3. protobuf-src crate (if bundled-protoc feature enabled)
/// 4. System PATH
fn find_protoc() -> PathBuf {
    // Conan protoc first — must be version-matched with the Conan protobuf
    // headers, so it takes priority over any system/env protoc.
    if let Some(p) = find_protoc_from_conan() {
        println!("cargo:warning=Using protoc from Conan: {}", p.display());
        return p;
    }

    // Check PROTOC env var
    if let Ok(protoc) = std::env::var("PROTOC") {
        let p = PathBuf::from(&protoc);
        if p.exists() {
            println!("cargo:warning=Using PROTOC from environment: {protoc}");
            return p;
        }
    }

    // Try protobuf-src crate if available
    #[cfg(feature = "bundled-protoc")]
    {
        let p = protobuf_src::protoc();
        println!("cargo:warning=Using bundled protoc: {}", p.display());
        return p;
    }

    // Fall back to system PATH
    #[allow(unreachable_code)]
    {
        if let Ok(p) = which::which("protoc") {
            println!("cargo:warning=Using system protoc: {}", p.display());
            return p;
        }
        panic!(
            "protoc not found. Either:\n\
             - Set PROTOC env var to the protoc binary path\n\
             - Install protoc (e.g. via Conan, chocolatey, or apt)\n\
             - Enable the 'bundled-protoc' feature to build from source"
        );
    }
}

/// Search the Conan output directory for the protoc binary.
/// Tries two strategies:
/// 1. Parse VirtualBuildEnv scripts (conanbuildenv-*.bat/.sh) for PATH entries
/// 2. Parse CMakeDeps .cmake files for protobuf PACKAGE_FOLDER paths
fn find_protoc_from_conan() -> Option<PathBuf> {
    // Conan with cmake_layout() puts generators in conan_output/build/generators/
    let generators_dir = Path::new("conan_output").join("build").join("generators");
    let conan_output = if generators_dir.is_dir() {
        generators_dir
    } else {
        let fallback = Path::new("conan_output").to_path_buf();
        if !fallback.is_dir() {
            return None;
        }
        fallback
    };

    let protoc_name = if cfg!(windows) { "protoc.exe" } else { "protoc" };

    // Strategy 1: Parse conanbuildenv scripts for PATH additions.
    // VirtualBuildEnv generates scripts like conanbuildenv-release-x86_64.bat
    // containing lines like:  set "PATH=C:\...\.conan2\p\proto...\bin;%PATH%"
    // or on unix:             export PATH="/.conan2/p/proto.../bin:$PATH"
    if let Ok(entries) = fs::read_dir(&conan_output) {
        for entry in entries.flatten() {
            let path = entry.path();
            let fname = path.file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
            let is_buildenv = fname.starts_with("conanbuildenv")
                && (fname.ends_with(".bat") || fname.ends_with(".sh") || fname.ends_with(".ps1"));
            if !is_buildenv {
                continue;
            }
            if let Ok(content) = fs::read_to_string(&path) {
                for line in content.lines() {
                    // Extract directory paths from PATH assignments
                    let paths = if line.contains("PATH=") || line.contains("PATH \"") {
                        // Split on ; (Windows) and : (Unix) path separators
                        line.split(&[';', ':', '"', '\''][..])
                            .filter(|p| Path::new(p).is_absolute())
                            .collect::<Vec<_>>()
                    } else {
                        continue;
                    };
                    for dir in paths {
                        let protoc = Path::new(dir).join(protoc_name);
                        if protoc.exists() {
                            return Some(protoc);
                        }
                    }
                }
            }
        }
    }

    // Strategy 2: Parse CMakeDeps .cmake files for protobuf package paths
    if let Ok(entries) = fs::read_dir(&conan_output) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.extension().map_or(false, |e| e == "cmake") {
                continue;
            }
            let fname = path.file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default();
            if !fname.contains("protobuf") {
                continue;
            }
            if let Ok(content) = fs::read_to_string(&path) {
                for line in content.lines() {
                    if line.contains("PACKAGE_FOLDER") || line.contains("_ROOT_") {
                        for part in line.split('"') {
                            let candidate = Path::new(part);
                            if candidate.is_absolute() && candidate.is_dir() {
                                let protoc = candidate.join("bin").join(protoc_name);
                                if protoc.exists() {
                                    return Some(protoc);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    None
}

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

/// Returns the Conan profile name for the current target platform.
fn conan_profile() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows-x64-static"
    } else if cfg!(target_os = "linux") {
        "linux-x64-static"
    } else if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            "macos-arm64-static"
        } else {
            "macos-x64-static"
        }
    } else {
        panic!("Unsupported target OS for Conan profile selection");
    }
}

/// Run `conan install` and return the path to the build directory containing
/// the generated CMake toolchain and find-package files.
fn conan_install(manifest_dir: &Path) -> Option<PathBuf> {
    let conanfile = manifest_dir.join("conanfile.py");
    if !conanfile.exists() {
        println!("cargo:warning=conanfile.py not found at {}", conanfile.display());
        return None;
    }

    // Check that conan is available
    if which::which("conan").is_err() {
        println!("cargo:warning=conan not found in PATH; falling back to ExternalProject");
        return None;
    }

    let profile = conan_profile();
    let profiles_dir = manifest_dir.join("conan").join("profiles");
    let profile_path = profiles_dir.join(profile);

    let conan_output_dir = manifest_dir.join("conan_output");
    fs::create_dir_all(&conan_output_dir).ok();

    println!(
        "cargo:warning=Running conan install with profile {} ...",
        profile
    );

    let mut cmd = Command::new("conan");
    cmd.arg("install")
        .arg(manifest_dir)
        .arg("--output-folder")
        .arg(&conan_output_dir)
        .arg("--build=missing");

    if profile_path.exists() {
        // --profile:host for the target libraries, --profile:build for build tools (protoc etc.)
        cmd.arg("--profile:host").arg(&profile_path);
        cmd.arg("--profile:build").arg(&profile_path);
    } else {
        println!(
            "cargo:warning=Conan profile {} not found, using default profile",
            profile_path.display()
        );
    }

    let status = cmd.status();
    match status {
        Ok(s) if s.success() => {
            println!("cargo:warning=Conan install succeeded");
            Some(conan_output_dir)
        }
        Ok(s) => {
            println!(
                "cargo:warning=Conan install failed with exit code {:?}; falling back to ExternalProject",
                s.code()
            );
            None
        }
        Err(e) => {
            println!(
                "cargo:warning=Failed to run conan: {e}; falling back to ExternalProject"
            );
            None
        }
    }
}

fn cmake_build() -> Result<Option<PathBuf>, std::io::Error> {
    let mut dst = Config::new("cpp/perspective");
    if let Some(cpp_build_dir) = std::option_env!("PSP_CPP_BUILD_DIR") {
        std::fs::create_dir_all(cpp_build_dir)?;
        dst.out_dir(cpp_build_dir);
    }

    let is_wasm = std::env::var("TARGET")
        .unwrap_or_default()
        .contains("wasm32");

    // Conan integration for native (non-WASM) builds.
    // Must run BEFORE find_protoc() so that protoc from the Conan
    // package cache is discoverable.
    let conan_output = if !is_wasm {
        let manifest_dir = std::fs::canonicalize(".")
            .expect("Failed to canonicalize current directory");
        conan_install(&manifest_dir)
    } else {
        None
    };

    let profile = std::env::var("PROFILE").unwrap();
    dst.always_configure(true);
    dst.define("CMAKE_BUILD_TYPE", profile.as_str());

    // When Conan is active, force cmake-rs to use "Release" config for
    // multi-config generators (MSVC). Conan's CMakeDeps only generates
    // target properties for the build_type in the profile (Release),
    // so MinSizeRel (cmake-rs default) would find no include dirs or libs.
    if conan_output.is_some() && cfg!(windows) {
        dst.profile("Release");
    }
    dst.define("ARROW_BUILD_EXAMPLES", "OFF");
    dst.define("RAPIDJSON_BUILD_EXAMPLES", "OFF");
    dst.define("ARROW_CXX_FLAGS_DEBUG", "-Wno-error");
    let protoc_path = find_protoc();
    dst.define(
        "PSP_PROTOC_PATH",
        protoc_path
            .parent()
            .expect("protoc path returned root path or empty string"),
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

    // Prevent vcpkg from interfering — we use Conan now.
    // Blank VCPKG_ROOT to prevent vcpkg toolchain loading.
    dst.env("VCPKG_ROOT", "");
    dst.define("VCPKG_MANIFEST_MODE", "OFF");

    if let Some(ref conan_dir) = conan_output {
        // Conan 2.x with cmake_layout() puts generators in build/generators/
        let generators_dir = conan_dir.join("build").join("generators");
        let toolchain_file = if generators_dir.join("conan_toolchain.cmake").exists() {
            generators_dir.join("conan_toolchain.cmake")
        } else {
            conan_dir.join("conan_toolchain.cmake")
        };

        if toolchain_file.exists() {
            println!(
                "cargo:warning=Using Conan toolchain at {}",
                toolchain_file.display()
            );

            // Conan's toolchain sets CMAKE_GENERATOR_TOOLSET=v143.
            // cmake-rs defaults to -Thost=x64 which conflicts.
            // Match exactly what Conan sets.
            if cfg!(windows) {
                dst.generator_toolset("v143");
            }

            dst.define("CMAKE_TOOLCHAIN_FILE", &toolchain_file);

            // Tell CMake where to find the Conan-generated Find*.cmake / *Config.cmake files
            let prefix_path = toolchain_file.parent().unwrap();
            dst.define("CMAKE_PREFIX_PATH", prefix_path);
        } else {
            println!(
                "cargo:warning=conan_toolchain.cmake not found in {}",
                conan_dir.display()
            );
        }
    } else if !is_wasm {
        println!("cargo:warning=Conan not available; falling back to ExternalProject dependency resolution");
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
            // When Conan is active, the Conan toolchain is already set as
            // CMAKE_TOOLCHAIN_FILE. When Conan is not active, set the
            // Darwin toolchain directly.
            if conan_output.is_none() || is_wasm {
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

    let is_wasm = std::env::var("TARGET")
        .unwrap_or_default()
        .contains("wasm32");

    let mut linked = std::collections::HashSet::new();

    if !is_wasm && which::which("conan").is_ok() {
        // Conan path: link psp + protos from cmake build, then Conan libs.
        // Conan places libraries in a well-known output directory.

        // Link psp from its build dir (may be in MinSizeRel/ on Windows)
        link_archives_flat(&build_dir, &mut linked)?;

        // Link protos from its build dir
        let protos_dir = build_dir.join("protos-build");
        link_archives_flat(&protos_dir, &mut linked)?;

        // Conan-installed libraries are found by CMake via find_package and
        // linked transitively. However, for static builds we also need to
        // ensure rustc sees all the archive search paths. The Conan generators
        // produce a list of library directories we can scan.
        // Conan with cmake_layout() puts generators in build/generators/
        let manifest_dir = std::fs::canonicalize(".")?;
        let generators_dir = manifest_dir.join("conan_output").join("build").join("generators");
        let conan_cmake_dir = if generators_dir.is_dir() {
            generators_dir
        } else {
            manifest_dir.join("conan_output")
        };
        if conan_cmake_dir.exists() {
            link_conan_libraries(&conan_cmake_dir, &mut linked)?;
        }
    } else {
        // ExternalProject path: recursive walk is fine since there's no
        // Conan output directory with duplicate entries.
        println!(
            "cargo:rustc-link-search=native={}/build",
            cmake_build_dir.display()
        );
        println!("cargo:rustc-link-lib=static=psp");
        link_cmake_static_archives(cmake_build_dir, &mut linked)?;
    }

    // Windows system libraries needed by Arrow and other C++ deps
    if cfg!(windows) {
        for lib in &["ole32", "shell32", "advapi32", "bcrypt", "ws2_32", "crypt32", "userenv"] {
            println!("cargo:rustc-link-lib=dylib={lib}");
        }

    }

    println!("cargo:rerun-if-changed=cpp/perspective");
    println!("cargo:rerun-if-changed=conanfile.py");
    Ok(())
}

/// Parse Conan-generated .cmake data files to find library directories and
/// link all static archives found there.
///
/// Conan data files use CMake variables like:
///   set(arrow_PACKAGE_FOLDER_RELEASE "C:/.conan2/p/b/arrow.../p")
///   set(arrow_LIB_DIRS_RELEASE "${arrow_PACKAGE_FOLDER_RELEASE}/lib")
/// We resolve these by first collecting PACKAGE_FOLDER values, then
/// substituting them in LIB_DIRS.
fn link_conan_libraries(
    conan_output: &Path,
    linked: &mut std::collections::HashSet<String>,
) -> Result<(), std::io::Error> {
    let mut package_folders: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut lib_dirs: Vec<PathBuf> = Vec::new();

    // First pass: collect all PACKAGE_FOLDER values
    for entry in fs::read_dir(conan_output)? {
        let path = entry?.path();
        if !path.extension().map_or(false, |e| e == "cmake") {
            continue;
        }
        if let Ok(content) = fs::read_to_string(&path) {
            for line in content.lines() {
                // Match: set(xxx_PACKAGE_FOLDER_RELEASE "C:/...")
                if line.contains("PACKAGE_FOLDER") && line.contains("set(") {
                    if let Some((var_name, value)) = parse_cmake_set(line) {
                        package_folders.insert(var_name, value);
                    }
                }
            }
        }
    }

    // Second pass: resolve LIB_DIRS using package folders
    for entry in fs::read_dir(conan_output)? {
        let path = entry?.path();
        if !path.extension().map_or(false, |e| e == "cmake") {
            continue;
        }
        if let Ok(content) = fs::read_to_string(&path) {
            for line in content.lines() {
                if !line.contains("_LIB_DIRS") || !line.contains("set(") {
                    continue;
                }
                if let Some((_var_name, value)) = parse_cmake_set(line) {
                    // Resolve ${var} references
                    let resolved = resolve_cmake_vars(&value, &package_folders);
                    let candidate = Path::new(&resolved);
                    if candidate.is_absolute() && candidate.is_dir() {
                        lib_dirs.push(candidate.to_path_buf());
                    }
                }
            }
        }
    }

    lib_dirs.sort();
    lib_dirs.dedup();

    for dir in &lib_dirs {
        println!("cargo:warning=Linking Conan libs from: {}", dir.display());
        link_archives_flat(dir, linked)?;
    }

    Ok(())
}

/// Parse a CMake set() line like: set(varname "value")
/// Returns (variable_name, value) or None.
fn parse_cmake_set(line: &str) -> Option<(String, String)> {
    let line = line.trim();
    let inner = line.strip_prefix("set(")?.strip_suffix(')')?;
    let space_pos = inner.find(|c: char| c == ' ' || c == '\t')?;
    let var_name = inner[..space_pos].to_string();
    let value_part = inner[space_pos..].trim();
    // Strip quotes
    let value = value_part.trim_matches('"').to_string();
    Some((var_name, value))
}

/// Resolve ${variable} references in a string using the provided map.
fn resolve_cmake_vars(
    input: &str,
    vars: &std::collections::HashMap<String, String>,
) -> String {
    let mut result = input.to_string();
    // Iteratively resolve ${...} references
    for _ in 0..10 {
        let mut changed = false;
        if let Some(start) = result.find("${") {
            if let Some(end) = result[start..].find('}') {
                let var_name = &result[start + 2..start + end];
                if let Some(value) = vars.get(var_name) {
                    result = format!("{}{}{}", &result[..start], value, &result[start + end + 1..]);
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    result
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
/// Used only for the ExternalProject (non-Conan) path.
fn link_cmake_static_archives(dir: &Path, linked: &mut std::collections::HashSet<String>) -> Result<(), std::io::Error> {
    if !dir.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            let name = path.file_name().map(|n| n.to_string_lossy());
            if name.as_deref() == Some("conan_output") {
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
