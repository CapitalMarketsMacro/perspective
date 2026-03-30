@echo off
setlocal enabledelayedexpansion

echo ============================================
echo  Perspective Native Build (Windows + vcpkg)
echo ============================================
echo.

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
echo --- Starting build ---
echo.

:: Generate placeholder for expression_gen.md if missing
if not exist "rust\perspective-client\docs" mkdir "rust\perspective-client\docs"
if not exist "rust\perspective-client\docs\expression_gen.md" (
    echo. > "rust\perspective-client\docs\expression_gen.md"
    echo [INFO] Created placeholder expression_gen.md
)

:: Generate proto.rs if missing
if not exist "rust\perspective-client\src\rust\proto.rs" (
    echo [INFO] Generating protobuf bindings (first-time setup)...
    cargo build -p perspective-client --features generate-proto,protobuf-src,omit_metadata
    if %errorlevel% neq 0 (
        echo [ERROR] Failed to generate protobuf bindings.
        exit /b 1
    )
    echo [OK] Protobuf bindings generated.
    echo.
)

:: Build perspective-server
echo [INFO] Building perspective-server (C++ engine)...
if "%USE_VCPKG%"=="1" (
    echo [INFO] Using vcpkg at %VCPKG_ROOT%
)
echo.

cargo build -p perspective-server --no-default-features
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Build failed. Check the output above for details.
    exit /b 1
)

echo.
echo ============================================
echo  Build succeeded!
echo ============================================

endlocal
