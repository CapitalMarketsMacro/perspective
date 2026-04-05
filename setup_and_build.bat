@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  Perspective - detect prerequisites, set up Conan, and build
::
::  Usage:
::    setup_and_build.bat            Build (always cleans CMake cache)
::    setup_and_build.bat --clean    Full clean (CMake cache + Cargo + Conan output)
:: ============================================================

set "REPO_ROOT=%~dp0"
set "CONAN_DIR=%REPO_ROOT%rust\perspective-server"
set "PROFILES_DIR=%CONAN_DIR%\conan\profiles"
set "PROFILE_NAME=windows-x64-static"
set "BUILD_DIR=%REPO_ROOT%rust\target\release\build"
set "CONAN_OUTPUT=%CONAN_DIR%\conan_output"
set "FULL_CLEAN=0"

:: Parse arguments
if "%~1"=="--clean" set "FULL_CLEAN=1"
if "%~1"=="-c" set "FULL_CLEAN=1"

echo.
echo ========================================================
echo   Perspective - Setup and Build
echo ========================================================
echo.
echo   [INFO] Platform: Windows / x64  -  Conan profile: %PROFILE_NAME%
echo.

:: ------------------------------------------------------------------
:: 0. Clean
:: ------------------------------------------------------------------
echo --- Cleaning build artifacts ---
echo.

:: Always clean CMake cache for perspective-server to avoid stale toolset errors
for /d %%d in ("%BUILD_DIR%\perspective-server-*") do (
    if exist "%%d\out\build\CMakeCache.txt" (
        echo   [CLEAN] Removing CMake cache: %%d\out\build\CMakeCache.txt
        del /q "%%d\out\build\CMakeCache.txt" 2>nul
    )
    if exist "%%d\out\build\CMakeFiles" (
        echo   [CLEAN] Removing CMakeFiles: %%d\out\build\CMakeFiles
        rmdir /s /q "%%d\out\build\CMakeFiles" 2>nul
    )
)

if "!FULL_CLEAN!"=="1" (
    echo   [CLEAN] Full clean requested (--clean)
    echo.

    :: Remove all perspective-server build dirs
    for /d %%d in ("%BUILD_DIR%\perspective-server-*") do (
        echo   [CLEAN] Removing %%d
        rmdir /s /q "%%d" 2>nul
    )

    :: Remove Conan output
    if exist "%CONAN_OUTPUT%" (
        echo   [CLEAN] Removing Conan output: %CONAN_OUTPUT%
        rmdir /s /q "%CONAN_OUTPUT%" 2>nul
    )

    :: Remove Cargo build artifacts for perspective crates
    if exist "%REPO_ROOT%rust\target\release\libperspective_server.rlib" (
        echo   [CLEAN] Removing compiled perspective crate artifacts
        del /q "%REPO_ROOT%rust\target\release\libperspective_server.rlib" 2>nul
        del /q "%REPO_ROOT%rust\target\release\libperspective_server.d" 2>nul
        del /q "%REPO_ROOT%rust\target\release\libperspective.rlib" 2>nul
        del /q "%REPO_ROOT%rust\target\release\libperspective.d" 2>nul
    )

    echo.
    echo   [OK]   Full clean done
)

echo.

:: ------------------------------------------------------------------
:: 1. Check prerequisites
:: ------------------------------------------------------------------
echo --- Checking prerequisites ---
echo.

set "HAS_RUST=0"
set "HAS_CMAKE=0"
set "HAS_MSVC=0"
set "HAS_PYTHON=0"
set "PIP_CMD="

:: Rust
where rustc >nul 2>&1
if %errorlevel% neq 0 goto :no_rust
set "HAS_RUST=1"
for /f "tokens=*" %%i in ('rustc --version') do echo   [OK]   %%i
goto :check_cmake
:no_rust
echo   [WARN] rustc not found - install from https://rustup.rs

:: CMake
:check_cmake
where cmake >nul 2>&1
if %errorlevel% neq 0 goto :no_cmake
set "HAS_CMAKE=1"
for /f "tokens=*" %%i in ('cmake --version') do (
    echo   [OK]   %%i
    goto :check_msvc
)
:no_cmake
echo   [WARN] cmake not found - install from https://cmake.org/download/

:: MSVC
:check_msvc
where cl >nul 2>&1
if %errorlevel% neq 0 goto :no_msvc
set "HAS_MSVC=1"
echo   [OK]   MSVC cl.exe found
goto :check_python
:no_msvc
echo   [WARN] MSVC cl.exe not found in PATH.
echo          Run from "x64 Native Tools Command Prompt for VS 2022".

:: Python / pip
:check_python
where python >nul 2>&1
if %errorlevel% neq 0 goto :try_python3
set "HAS_PYTHON=1"
set "PIP_CMD=python -m pip"
for /f "tokens=*" %%i in ('python --version') do echo   [OK]   %%i
goto :prereq_done

:try_python3
where python3 >nul 2>&1
if %errorlevel% neq 0 goto :no_python
set "HAS_PYTHON=1"
set "PIP_CMD=python3 -m pip"
for /f "tokens=*" %%i in ('python3 --version') do echo   [OK]   %%i
goto :prereq_done

:no_python
echo   [WARN] python not found - needed to install Conan

:prereq_done
echo.

:: Check hard blockers
if "!HAS_RUST!"=="0" (
    echo [ERROR] Cannot continue without Rust. Install from https://rustup.rs
    exit /b 1
)
if "!HAS_CMAKE!"=="0" (
    echo [ERROR] Cannot continue without CMake. Install from https://cmake.org/download/
    exit /b 1
)
if "!HAS_MSVC!"=="0" (
    echo   [NOTE] cl.exe not in PATH - CMake will try to locate MSVC automatically.
    echo          If the build fails, re-run from "x64 Native Tools Command Prompt".
)

:: ------------------------------------------------------------------
:: 2. Install / detect Conan
:: ------------------------------------------------------------------
echo --- Setting up Conan ---
echo.

set "CONAN_INSTALLED=0"
where conan >nul 2>&1
if %errorlevel% neq 0 goto :conan_missing
for /f "tokens=*" %%i in ('conan --version') do echo   [OK]   Conan already installed: %%i
set "CONAN_INSTALLED=1"
goto :conan_ready

:conan_missing
echo   [INFO] Conan not found - attempting to install via pip...
if "!PIP_CMD!"=="" goto :conan_no_pip

!PIP_CMD! install conan
if %errorlevel% neq 0 goto :conan_pip_failed

:: Verify conan is now available
where conan >nul 2>&1
if %errorlevel% neq 0 goto :conan_not_in_path
for /f "tokens=*" %%i in ('conan --version') do echo   [OK]   Conan installed: %%i
set "CONAN_INSTALLED=1"
goto :conan_ready

:conan_no_pip
echo   [WARN] pip not available, cannot auto-install Conan.
echo          Install manually: pip install conan
echo          Build will fall back to ExternalProject.
goto :conan_ready

:conan_pip_failed
echo   [WARN] pip install conan failed.
echo          Build will fall back to ExternalProject.
goto :conan_ready

:conan_not_in_path
echo   [WARN] Conan installed but not in PATH.
echo          You may need to restart your terminal.
echo          Build will fall back to ExternalProject.

:conan_ready
echo.

:: ------------------------------------------------------------------
:: 3. Initialize Conan profile
:: ------------------------------------------------------------------
if "!CONAN_INSTALLED!"=="0" goto :skip_conan_setup

echo --- Configuring Conan profile ---
echo.

:: Detect default profile if needed
conan profile show >nul 2>&1
if %errorlevel% neq 0 goto :conan_detect_profile
echo   [OK]   Default Conan profile exists
goto :conan_show_project_profile

:conan_detect_profile
echo   [INFO] No default Conan profile - running auto-detect...
conan profile detect
echo   [OK]   Default profile created

:conan_show_project_profile
set "PROFILE_FILE=%PROFILES_DIR%\%PROFILE_NAME%"
if not exist "%PROFILE_FILE%" goto :conan_no_project_profile
echo   [OK]   Project profile: %PROFILE_FILE%
echo.
echo   Profile contents:
type "%PROFILE_FILE%"
echo.
goto :conan_install_deps

:conan_no_project_profile
echo   [WARN] Project profile %PROFILE_NAME% not found
echo          Will use Conan's default profile
set "PROFILE_FILE="

:: ------------------------------------------------------------------
:: 4. Pre-install Conan dependencies
:: ------------------------------------------------------------------
:conan_install_deps
echo --- Installing C++ dependencies via Conan ---
echo.
echo   [INFO] This may take a while on first run (building Arrow, Boost, etc.)
echo   [INFO] Subsequent runs reuse the Conan cache at %%USERPROFILE%%\.conan2\
echo.

if not exist "%CONAN_OUTPUT%" mkdir "%CONAN_OUTPUT%"

if "!PROFILE_FILE!"=="" goto :conan_install_no_profile

conan install "%CONAN_DIR%" --output-folder "%CONAN_OUTPUT%" --build=missing --profile:host "%PROFILE_FILE%" -s:b compiler.cppstd=17
goto :conan_install_check

:conan_install_no_profile
conan install "%CONAN_DIR%" --output-folder "%CONAN_OUTPUT%" --build=missing

:conan_install_check
if %errorlevel% neq 0 goto :conan_install_failed
echo.
echo   [OK]   Conan dependencies installed
echo.
goto :skip_conan_setup

:conan_install_failed
echo.
echo   [WARN] Conan install failed - build will fall back to ExternalProject
echo.

:skip_conan_setup

:: ------------------------------------------------------------------
:: 5. Run the main build
:: ------------------------------------------------------------------
echo --- Building Perspective ---
echo.

if not exist "%REPO_ROOT%build_native.bat" (
    echo [ERROR] build_native.bat not found at %REPO_ROOT%
    exit /b 1
)

echo   [INFO] Running build_native.bat ...
echo.
call "%REPO_ROOT%build_native.bat"

endlocal
