@echo off
setlocal enabledelayedexpansion

echo ============================================
echo  Perspective Native Build (Windows + vcpkg)
echo ============================================
echo.

set "REPO_ROOT=%~dp0"
set "DIST_DIR=%REPO_ROOT%dist\perspective"

:: Check for Rust
where rustc >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] rustc not found in PATH.
    echo Install Rust from https://rustup.rs
    exit /b 1
)
for /f "tokens=*" %%i in ('rustc --version') do echo [OK] %%i

:: Check for CMake
where cmake >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] cmake not found in PATH.
    echo Install CMake 3.29.5+ from https://cmake.org/download/
    exit /b 1
)
for /f "tokens=*" %%i in ('cmake --version 2^>^&1') do (
    echo [OK] %%i
    goto :cmake_done
)
:cmake_done

:: Check for vcpkg
if not defined VCPKG_ROOT (
    echo [WARN] VCPKG_ROOT is not set.
    echo        The build will fall back to downloading dependencies via ExternalProject.
    echo        To use vcpkg, set VCPKG_ROOT to your vcpkg installation directory.
    echo.
    set "USE_VCPKG=0"
) else (
    if not exist "%VCPKG_ROOT%\vcpkg.exe" (
        echo [WARN] vcpkg.exe not found at %VCPKG_ROOT%
        echo        Run bootstrap-vcpkg.bat in your vcpkg directory first.
        echo        Falling back to ExternalProject.
        set "USE_VCPKG=0"
    ) else (
        echo [OK] vcpkg found at %VCPKG_ROOT%
        set "USE_VCPKG=1"
    )
)

:: Check for Visual Studio / MSVC
where cl >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [WARN] MSVC compiler (cl.exe) not found in PATH.
    echo        If the build fails, run this script from a "Developer Command Prompt"
    echo        or "x64 Native Tools Command Prompt for VS 2022".
)

echo.
echo --- Phase 1: Prerequisites ---
echo.

:: Generate placeholder for expression_gen.md if missing
if not exist "rust\perspective-client\docs" mkdir "rust\perspective-client\docs"
if not exist "rust\perspective-client\docs\expression_gen.md" (
    echo. > "rust\perspective-client\docs\expression_gen.md"
    echo [INFO] Created placeholder expression_gen.md
)

:: Generate proto.rs if missing
if not exist "rust\perspective-client\src\rust\proto.rs" (
    echo [INFO] Generating protobuf bindings (first-time setup^)...
    cargo build -p perspective-client --features generate-proto,protobuf-src,omit_metadata
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to generate protobuf bindings.
        exit /b 1
    )
    echo [OK] Protobuf bindings generated.
    echo.
)

echo.
echo --- Phase 2: Building C++ engine + Rust crates (release) ---
echo.

if "%USE_VCPKG%"=="1" (
    echo [INFO] Using vcpkg at %VCPKG_ROOT%
)

:: Build all three crates in release mode
cargo build --release -p perspective-client --features omit_metadata
if %errorlevel% neq 0 (
    echo [ERROR] perspective-client build failed.
    exit /b 1
)

cargo build --release -p perspective-server --no-default-features
if %errorlevel% neq 0 (
    echo [ERROR] perspective-server build failed.
    exit /b 1
)

cargo build --release -p perspective --features axum-ws
if %errorlevel% neq 0 (
    echo [ERROR] perspective build failed.
    exit /b 1
)

echo.
echo --- Phase 3: Deploying to %DIST_DIR% ---
echo.

:: Create dist layout
if exist "%DIST_DIR%" rmdir /s /q "%DIST_DIR%"
mkdir "%DIST_DIR%"
mkdir "%DIST_DIR%\lib"
mkdir "%DIST_DIR%\cpp_cache"
mkdir "%DIST_DIR%\example"

:: Copy Rust source crates (needed for path dependency)
xcopy /s /e /q /i "rust\perspective" "%DIST_DIR%\rust\perspective" >nul
xcopy /s /e /q /i "rust\perspective-client" "%DIST_DIR%\rust\perspective-client" >nul
xcopy /s /e /q /i "rust\perspective-server" "%DIST_DIR%\rust\perspective-server" >nul

:: Copy the pre-built C++ artifacts so downstream builds skip CMake
:: Find the perspective-server build output directory
for /d %%d in (rust\target\release\build\perspective-server-*) do (
    if exist "%%d\out" (
        echo [INFO] Caching C++ build artifacts from %%d\out
        xcopy /s /e /q /i "%%d\out" "%DIST_DIR%\cpp_cache" >nul
    )
)

:: Copy workspace Cargo.toml (needed for path deps resolution)
copy "Cargo.toml" "%DIST_DIR%\Cargo.toml" >nul

:: Create the example project
(
echo [package]
echo name = "my-perspective-app"
echo version = "0.1.0"
echo edition = "2024"
echo.
echo [features]
echo default = ["perspective/axum-ws"]
echo.
echo [dependencies]
echo perspective = { path = "rust/perspective", default-features = false, features = ["axum-ws"] }
echo axum = { version = "^0.8", features = ["ws"] }
echo tokio = { version = "1", features = ["full"] }
echo tower-http = { version = "0.5", features = ["fs"] }
echo tracing = "0.1"
echo tracing-subscriber = { version = "0.3", features = ["env-filter"] }
echo.
echo [workspace]
echo members = []
echo.
echo # Resolve path dependencies to bundled crates
echo [patch.crates-io]
echo perspective = { path = "rust/perspective" }
echo perspective-client = { path = "rust/perspective-client" }
echo perspective-server = { path = "rust/perspective-server" }
) > "%DIST_DIR%\example\Cargo.toml"

mkdir "%DIST_DIR%\example\src"
(
echo use perspective::server::Server;
echo use perspective::client::{TableInitOptions, UpdateData};
echo use axum::{Router, routing::get};
echo use std::net::SocketAddr;
echo.
echo #[tokio::main]
echo async fn main^(^) -^> Result^<^(^), Box^<dyn std::error::Error + Send + Sync^>^> {
echo     tracing_subscriber::fmt::init^(^);
echo.
echo     let server = Server::new^(None^);
echo.
echo     // Load CSV data
echo     let client = server.new_local_client^(^);
echo     let csv = "x,y,z\n1,100,a\n2,200,b\n3,300,c\n4,400,d".to_string^(^);
echo     let mut opts = TableInitOptions::default^(^);
echo     opts.set_name^("my_table"^);
echo     client.table^(UpdateData::Csv^(csv^).into^(^), opts^).await?;
echo     client.close^(^).await;
echo.
echo     // Start WebSocket server
echo     let app = Router::new^(^)
echo         .route^("/ws", perspective::axum::websocket_handler^(^)^)
echo         .with_state^(server^);
echo.
echo     let addr = SocketAddr::from^(^([0, 0, 0, 0], 3000^)^);
echo     tracing::info!^("listening on {}", addr^);
echo     let listener = tokio::net::TcpListener::bind^(addr^).await?;
echo     axum::serve^(listener, app^).await?;
echo     Ok^(^(^)^)
echo }
) > "%DIST_DIR%\example\src\main.rs"

:: Create env setup script for consumers
(
echo @echo off
echo :: Set these before building projects that depend on perspective
echo :: This skips the C++ rebuild by reusing pre-built artifacts
echo set "PSP_CPP_BUILD_DIR=%DIST_DIR%\cpp_cache"
echo set "VCPKG_ROOT=%VCPKG_ROOT%"
echo echo [OK] Perspective environment configured.
echo echo     PSP_CPP_BUILD_DIR=%%PSP_CPP_BUILD_DIR%%
echo echo     VCPKG_ROOT=%%VCPKG_ROOT%%
) > "%DIST_DIR%\env.bat"

echo.
echo ============================================
echo  Build succeeded!
echo ============================================
echo.
echo  Deployed to: %DIST_DIR%
echo.
echo  Contents:
echo    rust\              - Source crates (path dependency)
echo    cpp_cache\         - Pre-built C++ artifacts
echo    env.bat            - Set environment to skip C++ rebuild
echo    example\           - Starter project template
echo.
echo  To use in your project:
echo    1. Run env.bat to set PSP_CPP_BUILD_DIR
echo    2. Add perspective as a path dependency (see example\Cargo.toml)
echo    3. cargo build
echo.
echo  The C++ engine will NOT rebuild as long as PSP_CPP_BUILD_DIR
echo  points to the cpp_cache directory.
echo.

endlocal
