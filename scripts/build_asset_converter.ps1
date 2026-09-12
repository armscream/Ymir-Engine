# scripts/build_asset_converter.ps1
# Builds Engine/src/Tools/asset_converter/ with MSVC environment loaded.
# Requires meshoptimizer.lib + imgui_windows_x64.lib to already exist.

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    Write-Host "[asset_converter] ERROR: vcvars64.bat not found" -ForegroundColor Red
    exit 1
}

# Load MSVC environment into this process.
Write-Host "[asset_converter] Loading MSVC environment..."
$vcvarsCmd = "`"$vcvars`" >nul && set"
$envLines = & cmd.exe /c $vcvarsCmd
foreach ($line in $envLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
    }
}

$outPath  = Join-Path $repoRoot "Project\bin\Tools\asset_converter.exe"
$srcDir   = Join-Path $repoRoot "Engine\src\Tools\asset_converter"
$meshoptLib = Join-Path $repoRoot "Engine\src\dependencies/meshoptimizer/meshoptimizer.lib"
$imguiLib   = Join-Path $repoRoot "Engine/src/dependencies/imgui/imgui_windows_x64.lib"

if (-not (Test-Path $meshoptLib)) {
    Write-Host "[asset_converter] meshoptimizer.lib not found. Run scripts/build_meshopt.ps1 first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $imguiLib)) {
    Write-Host "[asset_converter] imgui_windows_x64.lib not found. Run scripts/build_imgui.ps1 first." -ForegroundColor Red
    exit 1
}

$outDir = Split-Path -Parent $outPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host "[asset_converter] odin build $srcDir -> $outPath"
& odin.exe build "$srcDir" `
    -out:"$outPath" `
    -vet `
    -debug
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    Write-Host "[asset_converter] build failed with exit code $rc" -ForegroundColor Red
    exit $rc
}

$size = (Get-Item $outPath).Length
Write-Host "[asset_converter] OK: $outPath ($size bytes)" -ForegroundColor Green

# Copy SDL3.dll next to the binary so the tool can launch.
$sdl3Dll = "C:\Odin\vendor\sdl3\SDL3.dll"
if (Test-Path $sdl3Dll) {
    $dst = Join-Path $outDir "SDL3.dll"
    Copy-Item -Path $sdl3Dll -Destination $dst -Force
    Write-Host "[asset_converter] deployed SDL3.dll"
} else {
    Write-Host "[asset_converter] WARNING: SDL3.dll not found at $sdl3Dll; tool may not launch" -ForegroundColor Yellow
}

exit 0
