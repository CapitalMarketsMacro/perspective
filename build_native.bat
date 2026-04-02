@echo off
setlocal enabledelayedexpansion

echo ============================================
echo  Perspective Native Build (Windows + Conan)
echo ============================================
echo.

set "REPO_ROOT=%~dp0"
set "DIST_DIR=%REPO_ROOT%dist\perspective"

:: ---- Check Rust ----
where rustc >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] rustc not found in PATH.
    echo Install Rust from https://rustup.rs
    exit /b 1
)
for /f "tokens=*" %%i in ('rustc --version') do echo [OK] %%i

:: ---- Check CMake ----
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

:: ---- Check Conan ----
set "USE_CONAN=0"
where conan >nul 2>&1
if %errorlevel% neq 0 (
    echo [WARN] conan not found in PATH.
    echo        Build will fall back to downloading dependencies via ExternalProject.
    echo        To use Conan, install it: pip install conan
    goto :conan_done
)
for /f "tokens=*" %%i in ('conan --version') do echo [OK] %%i
set "USE_CONAN=1"
:conan_done

:: ---- Check MSVC ----
where cl >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [WARN] MSVC compiler cl.exe not found in PATH.
    echo        Run this from "x64 Native Tools Command Prompt for VS 2022" if build fails.
)

echo.
echo --- Phase 1: Prerequisites ---
echo.

:: ---- expression_gen.md ----
if not exist "rust\perspective-client\docs" mkdir "rust\perspective-client\docs"
if not exist "rust\perspective-client\docs\expression_gen.md" (
    echo. > "rust\perspective-client\docs\expression_gen.md"
    echo [INFO] Created placeholder expression_gen.md
)

:: ---- proto.rs ----
if exist "rust\perspective-client\src\rust\proto.rs" goto :proto_done
echo [INFO] Generating protobuf bindings ...
cargo build -p perspective-client --features generate-proto,protobuf-src,omit_metadata
if %errorlevel% neq 0 (
    echo [ERROR] Failed to generate protobuf bindings.
    exit /b 1
)
echo [OK] Protobuf bindings generated.
echo.
:proto_done

echo.
echo --- Phase 2: Building C++ engine + Rust crates (release) ---
echo.

if "%USE_CONAN%"=="1" echo [INFO] Conan is available and will be used for C++ dependencies

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
echo --- Phase 3: Deploying to dist\perspective ---
echo.

:: ---- Create dist layout ----
if exist "%DIST_DIR%" rmdir /s /q "%DIST_DIR%"
mkdir "%DIST_DIR%"
mkdir "%DIST_DIR%\lib"
mkdir "%DIST_DIR%\cpp_cache"
mkdir "%DIST_DIR%\example\src"

:: ---- Copy Rust source crates ----
xcopy /s /e /q /i "rust\perspective" "%DIST_DIR%\rust\perspective" >nul
xcopy /s /e /q /i "rust\perspective-client" "%DIST_DIR%\rust\perspective-client" >nul
xcopy /s /e /q /i "rust\perspective-server" "%DIST_DIR%\rust\perspective-server" >nul

:: ---- Cache only the needed pre-built .lib files (not entire build tree) ----
for /d %%d in (rust\target\release\build\perspective-server-*) do (
    if exist "%%d\out\build" (
        echo [INFO] Caching C++ build artifacts from %%d\out\build
        mkdir "%DIST_DIR%\cpp_cache\build" 2>nul
        :: psp.lib (may be in MinSizeRel/ or Release/)
        for /r "%%d\out\build" %%f in (psp.lib) do (
            echo   [LIB] %%f
            mkdir "%DIST_DIR%\cpp_cache\build\%%~pf" 2>nul
            copy "%%f" "%DIST_DIR%\cpp_cache\build\%%~pf" >nul 2>nul
        )
        :: protos.lib
        for /r "%%d\out\build\protos-build" %%f in (protos.lib) do (
            echo   [LIB] %%f
            mkdir "%DIST_DIR%\cpp_cache\build\protos-build\%%~pf" 2>nul
            copy "%%f" "%DIST_DIR%\cpp_cache\build\protos-build\%%~pf" >nul 2>nul
        )
        :: Conan libs are linked transitively via CMake; cache them from
        :: the Conan output directory if present
        if exist "%%d\out\conan_output" (
            mkdir "%DIST_DIR%\cpp_cache\conan_libs" 2>nul
            echo   [CONAN] Caching Conan library artifacts
        )
    )
)

:: ---- Copy workspace Cargo.toml ----
copy "Cargo.toml" "%DIST_DIR%\Cargo.toml" >nul

:: ---- Create example Cargo.toml ----
> "%DIST_DIR%\example\Cargo.toml" (
    echo [package]
    echo name = "my-perspective-app"
    echo version = "0.1.0"
    echo edition = "2024"
    echo.
    echo [features]
    echo default = ["perspective/axum-ws"]
    echo.
    echo [dependencies]
    echo perspective = { path = "../rust/perspective", default-features = false, features = ["axum-ws"] }
    echo axum = { version = "^0.8", features = ["ws"] }
    echo tokio = { version = "1", features = ["full"] }
    echo tower-http = { version = "0.5", features = ["fs"] }
    echo tracing = "0.1"
    echo tracing-subscriber = { version = "0.3", features = ["env-filter"] }
    echo.
    echo [workspace]
    echo members = []
    echo.
    echo [patch.crates-io]
    echo perspective = { path = "../rust/perspective" }
    echo perspective-client = { path = "../rust/perspective-client" }
    echo perspective-server = { path = "../rust/perspective-server" }
)

:: ---- Create example main.rs ----
> "%DIST_DIR%\example\src\main.rs" (
    echo use std::net::SocketAddr;
    echo use axum::Router;
    echo use perspective::server::Server;
    echo use perspective::client::{TableInitOptions, UpdateData};
    echo.
    echo #[tokio::main]
    echo async fn main^(^) {
    echo     tracing_subscriber::fmt::init^(^);
    echo     let server = Server::new^(None^);
    echo     let client = server.new_local_client^(^);
    echo     let csv = "x,y\n1,100\n2,200\n3,300".to_string^(^);
    echo     let mut opts = TableInitOptions::default^(^);
    echo     opts.set_name^("my_table"^);
    echo     client.table^(UpdateData::Csv^(csv^).into^(^), opts^).await.unwrap^(^);
    echo     client.close^(^).await;
    echo     let app = Router::new^(^)
    echo         .route^("/ws", perspective::axum::websocket_handler^(^)^)
    echo         .with_state^(server^);
    echo     let addr = SocketAddr::from^(^([0, 0, 0, 0], 3000^)^);
    echo     println!^("Listening on http://localhost:3000"^);
    echo     let listener = tokio::net::TcpListener::bind^(addr^).await.unwrap^(^);
    echo     axum::serve^(listener, app^).await.unwrap^(^);
    echo }
)

:: ---- Create env.bat for consumers ----
> "%DIST_DIR%\env.bat" (
    echo @echo off
    echo set "PSP_CPP_BUILD_DIR=%DIST_DIR%\cpp_cache"
    echo echo [OK] Perspective environment configured.
    echo echo     PSP_CPP_BUILD_DIR=%%PSP_CPP_BUILD_DIR%%
)

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
echo    1. Run dist\perspective\env.bat
echo    2. Add perspective as a path dependency (see example\Cargo.toml)
echo    3. cargo build
echo.

endlocal
