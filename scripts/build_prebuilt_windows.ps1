#Requires -Version 5.1
<#
.SYNOPSIS
    Builds shaderc & qtadvanceddocking from source on Windows.

.DESCRIPTION
    Builds the precompiled libraries for Windows x64 and packages them into the
    prebuilt/windows/ layout that this repo's release workflow publishes and the
    Neurus build consumes (prebuilt/windows/<name>/lib/...).

    The sources are the nested submodules under src/ (shaderc,
    qtadvanceddocking): Neurus-Lib owns both the sources and the C++ standard
    the archives must be built with.

    Output:
      prebuilt/windows/shaderc/lib/shaderc_shared.dll
      prebuilt/windows/shaderc/lib/shaderc_shared.lib
      prebuilt/windows/qtadvanceddocking/lib/qtadvanceddocking-qt6_static.lib
      prebuilt/windows/qtadvanceddocking/lib/qtadvanceddocking-qt6d_static.lib
      prebuilt/windows/qtadvanceddocking/build_info.txt

    Uses CMake's default generator (Visual Studio on a standard Windows dev
    install), so no Developer Command Prompt is required. Qt must be
    discoverable through CMAKE_PREFIX_PATH (set by jurplel/install-qt-action in
    CI, or by a Qt maintenance-tool installation).

.PARAMETER Clean
    Remove previous build artifacts before building. With -AdsOnly, only the
    ADS artifacts are removed, so the existing shaderc DLLs are kept.

.PARAMETER AdsOnly
    Rebuild only qtadvanceddocking, skipping shaderc. ADS must be rebuilt
    whenever the Qt version changes; shaderc links no Qt and need not be.

.PARAMETER Help
    Show usage.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_prebuilt_windows.ps1
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$AdsOnly,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Step([string]$Message) { Write-Host "`n>>> $Message" -ForegroundColor Cyan }
function Ok([string]$Message)   { Write-Host "  OK: $Message" -ForegroundColor Green }
function Warn([string]$Message) { Write-Host "  WARN: $Message" -ForegroundColor Yellow }
function Fail([string]$Message) { Write-Host "  FAIL: $Message" -ForegroundColor Red; exit 1 }

# Run an external command and fail with a clear message on a non-zero exit.
function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    & $Command
    if ($LASTEXITCODE -ne 0) { Fail "$What (exit code $LASTEXITCODE)" }
}

# First file matching -Filter under any of -Roots, in order, or $null.
function Find-TargetFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$Roots,
        [Parameter(Mandatory = $true)][string]$Filter
    )
    foreach ($root in $Roots) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "Required command '$Name' not found. Please install it first."
    }
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if ($Help) {
    Write-Host "Usage: scripts\build_prebuilt_windows.ps1 [-Clean] [-AdsOnly] [-Help]"
    Write-Host ""
    Write-Host "  -Clean     Remove previous build artifacts before building"
    Write-Host "             (with -AdsOnly, only the ADS artifacts, so the"
    Write-Host "             existing shaderc DLLs are kept)"
    Write-Host "  -AdsOnly   Rebuild only qtadvanceddocking, skipping shaderc."
    Write-Host "             ADS must be rebuilt whenever the Qt version"
    Write-Host "             changes; shaderc links no Qt and need not be."
    exit 0
}

# ---------------------------------------------------------------------------
# Project root detection
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path

if (-not (Test-Path (Join-Path $ProjectRoot 'scripts\ads_standalone\CMakeLists.txt'))) {
    Fail "Cannot find scripts\ads_standalone\CMakeLists.txt in $ProjectRoot - is scripts\ inside the Neurus-Lib root?"
}

Write-Host "=== Neurus Windows x64 Library Builder ==="
Write-Host "  Project root: $ProjectRoot"

# ---------------------------------------------------------------------------
# Clean previous builds if requested
#
# Under -AdsOnly the clean is narrowed to the ADS artifacts: wiping
# prebuilt\windows\shaderc\ as well would leave the tree with no shaderc DLLs
# and no step that rebuilds them, so the release archive packed afterwards
# would silently ship ADS only.
# ---------------------------------------------------------------------------
if ($Clean) {
    if ($AdsOnly) {
        Step "Cleaning previous ADS build artifacts (-AdsOnly)"
        $CleanDirs = @(
            (Join-Path $ProjectRoot 'build\_ads_windows_release'),
            (Join-Path $ProjectRoot 'build\_ads_windows_debug'),
            (Join-Path $ProjectRoot 'prebuilt\windows\qtadvanceddocking')
        )
    } else {
        Step "Cleaning previous build artifacts"
        $CleanDirs = @(
            (Join-Path $ProjectRoot 'build\_shaderc_windows'),
            (Join-Path $ProjectRoot 'build\_ads_windows_release'),
            (Join-Path $ProjectRoot 'build\_ads_windows_debug'),
            (Join-Path $ProjectRoot 'prebuilt\windows')
        )
    }
    foreach ($dir in $CleanDirs) {
        if (Test-Path $dir) {
            Write-Host "  Removing $dir"
            Remove-Item -Recurse -Force $dir
        }
    }
    Ok "Clean complete"
}

# ---------------------------------------------------------------------------
# Ensure output directories exist
# ---------------------------------------------------------------------------
$ShadercOut = Join-Path $ProjectRoot 'prebuilt\windows\shaderc\lib'
$AdsOut     = Join-Path $ProjectRoot 'prebuilt\windows\qtadvanceddocking\lib'
$AdsRootOut = Join-Path $ProjectRoot 'prebuilt\windows\qtadvanceddocking'

New-Item -ItemType Directory -Force -Path $ShadercOut | Out-Null
New-Item -ItemType Directory -Force -Path $AdsOut | Out-Null

# The ADS archives carry coalesced instantiations of Qt's inline container
# templates, so they must be compiled at the same C++ standard as the consuming
# project. Neurus-Lib owns the sources and therefore the standard: it is the
# same 20 the Neurus root CMakeLists pins, and the one stamped into
# build_info.txt below.
$NeurusCxxStandard = '20'

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
Step "Preflight checks"
Require-Command cmake
Require-Command git
Require-Command python
Ok "All required commands found"

# =============================
#  shaderc
# =============================
if ($AdsOnly) {
    Step "Skipping shaderc (-AdsOnly)"
} else {
    Step "Building shaderc"

    # --- Initialize submodule ---
    Step "shaderc: Initializing submodule"
    Invoke-Checked -What "Failed to initialize shaderc submodule" -Command {
        git -C $ProjectRoot submodule update --init --depth 1 src/shaderc
    }
    Ok "shaderc submodule initialized"

    # --- Sync third-party deps (glslang, spirv-tools, spirv-headers) ---
    Step "shaderc: Syncing dependencies (glslang, spirv-tools, spirv-headers)"
    Invoke-Checked -What "Failed to sync shaderc dependencies (git-sync-deps)" -Command {
        python (Join-Path $ProjectRoot 'src\shaderc\utils\git-sync-deps')
    }
    Ok "shaderc dependencies synced"

    # --- CMake configure (Release, shared) ---
    # libshaderc builds both a static and a shared target unconditionally;
    # shaderc_shared is the one the Neurus build links against.
    Step "shaderc: CMake configure (Release, shared)"
    $ShadercBuild = Join-Path $ProjectRoot 'build\_shaderc_windows'
    $ShadercCmakeArgs = @(
        '-S', (Join-Path $ProjectRoot 'src\shaderc')
        '-B', $ShadercBuild
        '-DSHADERC_SKIP_TESTS=ON'
        '-DSHADERC_ENABLE_EXAMPLES=OFF'
        '-DSHADERC_SKIP_INSTALL=OFF'
        "-DCMAKE_INSTALL_PREFIX=$(Join-Path $ShadercBuild 'install')"
        '-DSHADERC_ENABLE_HLSL=OFF'
        '-DENABLE_OPT=OFF'
    )
    Invoke-Checked -What "shaderc CMake configure failed" -Command { cmake @ShadercCmakeArgs }
    Ok "shaderc configured"

    # --- Build ---
    Step "shaderc: Building (Release)"
    Invoke-Checked -What "shaderc build failed" -Command {
        cmake --build $ShadercBuild --config Release
    }
    Ok "shaderc built"

    # --- Install ---
    Step "shaderc: Installing (Release)"
    Invoke-Checked -What "shaderc install failed" -Command {
        cmake --install $ShadercBuild --config Release
    }
    Ok "shaderc installed"

    # --- Copy DLL + import lib ---
    Step "shaderc: Copying DLL + import lib to prebuilt\windows\shaderc\lib\"
    $ShadercInstall = Join-Path $ShadercBuild 'install'
    $ShadercDll = Find-TargetFile -Roots @($ShadercInstall, $ShadercBuild) -Filter 'shaderc_shared.dll'
    $ShadercLib = Find-TargetFile -Roots @($ShadercInstall, $ShadercBuild) -Filter 'shaderc_shared.lib'
    if (-not $ShadercDll) { Fail "shaderc_shared.dll not found under $ShadercInstall or $ShadercBuild" }
    if (-not $ShadercLib) { Fail "shaderc_shared.lib not found under $ShadercInstall or $ShadercBuild" }
    Copy-Item $ShadercDll (Join-Path $ShadercOut 'shaderc_shared.dll') -Force
    Copy-Item $ShadercLib (Join-Path $ShadercOut 'shaderc_shared.lib') -Force
    Ok "shaderc DLL and import lib copied to $ShadercOut"
}

# =============================
#  qtadvanceddocking (Release)
# =============================
Step "Building qtadvanceddocking - Release"

Step "qtadvanceddocking: Initializing submodule"
Invoke-Checked -What "Failed to initialize qtadvanceddocking submodule" -Command {
    git -C $ProjectRoot submodule update --init --depth 1 src/qtadvanceddocking
}
Ok "qtadvanceddocking submodule initialized"

# --- CMake Configure (Release) ---
# Configured through scripts\ads_standalone, not src\qtadvanceddocking
# directly: the wrapper pins the C++ standard (the submodule hardcodes 17) and
# writes the build_info.txt stamp that the Neurus build checks before trusting
# these archives.
Step "qtadvanceddocking: CMake configure (Release, C++$NeurusCxxStandard)"
$AdsReleaseBuild = Join-Path $ProjectRoot 'build\_ads_windows_release'
$AdsCmakeCommon = @(
    '-S', (Join-Path $ProjectRoot 'scripts\ads_standalone')
    "-DNEURUS_ADS_SOURCE_DIR=$(Join-Path $ProjectRoot 'src\qtadvanceddocking')"
    "-DNEURUS_ADS_CXX_STANDARD=$NeurusCxxStandard"
)
Invoke-Checked -What "qtadvanceddocking Release CMake configure failed" -Command {
    cmake @AdsCmakeCommon -B $AdsReleaseBuild
}
Ok "qtadvanceddocking Release configured"

# --- Build (Release) ---
Step "qtadvanceddocking: Building (Release)"
Invoke-Checked -What "qtadvanceddocking Release build failed" -Command {
    cmake --build $AdsReleaseBuild --config Release
}
Ok "qtadvanceddocking Release built"

# --- Copy static lib ---
Step "qtadvanceddocking: Copying Release static lib"
$AdsReleaseLib = Find-TargetFile -Roots @($AdsReleaseBuild) -Filter 'qtadvanceddocking-qt6_static.lib'
if (-not $AdsReleaseLib) {
    # Try alternate naming patterns
    $AdsReleaseLib = Find-TargetFile -Roots @($AdsReleaseBuild) -Filter 'qtadvanceddocking-qt6*.lib'
    if (-not $AdsReleaseLib) {
        Fail "Could not find qtadvanceddocking Release static library in $AdsReleaseBuild"
    }
    Warn "Expected qtadvanceddocking-qt6_static.lib, found $(Split-Path -Leaf $AdsReleaseLib)"
}
Copy-Item $AdsReleaseLib (Join-Path $AdsOut 'qtadvanceddocking-qt6_static.lib') -Force
Ok "qtadvanceddocking Release lib copied to $(Join-Path $AdsOut 'qtadvanceddocking-qt6_static.lib')"

# =============================
#  qtadvanceddocking (Debug)
# =============================
Step "Building qtadvanceddocking - Debug"

# --- CMake Configure (Debug) ---
Step "qtadvanceddocking: CMake configure (Debug, C++$NeurusCxxStandard)"
$AdsDebugBuild = Join-Path $ProjectRoot 'build\_ads_windows_debug'
Invoke-Checked -What "qtadvanceddocking Debug CMake configure failed" -Command {
    cmake @AdsCmakeCommon -B $AdsDebugBuild
}
Ok "qtadvanceddocking Debug configured"

# --- Build (Debug) ---
Step "qtadvanceddocking: Building (Debug)"
Invoke-Checked -What "qtadvanceddocking Debug build failed" -Command {
    cmake --build $AdsDebugBuild --config Debug
}
Ok "qtadvanceddocking Debug built"

# --- Copy static lib ---
Step "qtadvanceddocking: Copying Debug static lib"
$AdsDebugLib = Find-TargetFile -Roots @($AdsDebugBuild) -Filter 'qtadvanceddocking-qt6d_static.lib'
if (-not $AdsDebugLib) {
    # Try alternate naming patterns (debug builds may use different suffix)
    $AdsDebugLib = Find-TargetFile -Roots @($AdsDebugBuild) -Filter 'qtadvanceddocking-qt6*d_static.lib'
    if (-not $AdsDebugLib) {
        # Broader search - pick any static lib that isn't the release one
        $AdsDebugLib = Find-TargetFile -Roots @($AdsDebugBuild) -Filter 'qtadvanceddocking-qt6*.lib'
        if (-not $AdsDebugLib) {
            Fail "Could not find qtadvanceddocking Debug static library in $AdsDebugBuild"
        }
    }
    Warn "Expected qtadvanceddocking-qt6d_static.lib, found $(Split-Path -Leaf $AdsDebugLib)"
}
Copy-Item $AdsDebugLib (Join-Path $AdsOut 'qtadvanceddocking-qt6d_static.lib') -Force
Ok "qtadvanceddocking Debug lib copied to $(Join-Path $AdsOut 'qtadvanceddocking-qt6d_static.lib')"

# --- Compatibility stamp ---
# The Neurus build refuses these archives unless the stamp matches the
# consuming build's Qt version and C++ standard, which is what stops a stale
# archive from producing an ODR mismatch that only shows up as a runtime crash.
Step "qtadvanceddocking: Writing compatibility stamp"
$ReleaseStamp = Join-Path $AdsReleaseBuild 'build_info.txt'
$DebugStamp   = Join-Path $AdsDebugBuild 'build_info.txt'
if (-not (Test-Path $ReleaseStamp)) { Fail "Release build_info.txt not found at $ReleaseStamp" }
if (-not (Test-Path $DebugStamp))   { Fail "Debug build_info.txt not found at $DebugStamp" }

$ReleaseText = Get-Content -Raw $ReleaseStamp
$DebugText   = Get-Content -Raw $DebugStamp
if ($ReleaseText -ne $DebugText) {
    Fail ("Release and Debug ADS builds disagree on Qt version / standard - refusing to stamp.`n" +
          "  Release: $($ReleaseText -replace '\r?\n', ' ')`n" +
          "  Debug:   $($DebugText -replace '\r?\n', ' ')")
}
Copy-Item $DebugStamp (Join-Path $AdsRootOut 'build_info.txt') -Force
Ok "Stamp written to $(Join-Path $AdsRootOut 'build_info.txt')"
Get-Content $ReleaseStamp | Where-Object { $_ -notmatch '^#' } | ForEach-Object { Write-Host "    $_" }

# =============================
#  Summary
# =============================
Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host ""
Write-Host "Precompiled Windows x64 libraries built at: prebuilt\windows\"
Write-Host ""
Write-Host "Contents:"
Write-Host "  prebuilt\windows\shaderc\lib\"
if (Test-Path $ShadercOut) { Get-ChildItem $ShadercOut | ForEach-Object { Write-Host "    $($_.Name)" } }
Write-Host "  prebuilt\windows\qtadvanceddocking\lib\"
if (Test-Path $AdsOut) { Get-ChildItem $AdsOut | ForEach-Object { Write-Host "    $($_.Name)" } }
Write-Host "  prebuilt\windows\qtadvanceddocking\build_info.txt"
Write-Host ""
Write-Host "To create a release archive locally (CI publishes a lib-<sha12> release on"
Write-Host "every push to main - see .github/workflows/build-libs.yml). The archive"
Write-Host "holds the platform directory, so it extracts into prebuilt\:"
Write-Host "  Compress-Archive -Path prebuilt\windows -DestinationPath windows-x64.zip"
Write-Host "  (Get-FileHash windows-x64.zip -Algorithm SHA256).Hash | Set-Content windows-x64.zip.sha256"
