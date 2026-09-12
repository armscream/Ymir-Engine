# scripts/build_imgui.ps1
# Builds the Dear ImGui static library used by the Bifrost
# asset_converter (Engine/src/Tools/asset_converter/). Requires
# MSVC Build Tools and the assets from Capati/odin-imgui (already
# vendored under Engine/src/dependencies/imgui/).
#
# The repo's imgui.odin foreign-imports `imgui_windows_x64.lib`;
# this script produces that file and drops it next to the bindings.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/build_imgui.ps1

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    Write-Host "[imgui] ERROR: vcvars64.bat not found" -ForegroundColor Red
    exit 1
}

$imguiDir  = Join-Path $repoRoot "Engine\src\dependencies\imgui"
$slnFile   = Join-Path $imguiDir "build\make\windows\ImGui.sln"
$outLib    = Join-Path $imguiDir "imgui_windows_x64.lib"

if (-not (Test-Path $slnFile)) {
    Write-Host "[imgui] ERROR: ImGui.sln not found. Run premake5 first:" -ForegroundColor Red
    Write-Host "         cd '$imguiDir' && premake5 --backends=sdl3 vs2022" -ForegroundColor Red
    exit 1
}

# Find msbuild.exe.
$msbuildDirs = Get-ChildItem "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild" -ErrorAction SilentlyContinue
$msbuildExe  = $msbuildDirs | ForEach-Object {
    Get-ChildItem (Join-Path $_.FullName "Bin\MSBuild.exe") -ErrorAction SilentlyContinue
} | Select-Object -First 1 -ExpandProperty FullName

if (-not $msbuildExe) {
    Write-Host "[imgui] ERROR: msbuild.exe not found under VS Build Tools" -ForegroundColor Red
    exit 1
}

Write-Host "[imgui] MSBuild: $msbuildExe"
Write-Host "[imgui] Solution: $slnFile"
Write-Host "[imgui] Output: $outLib"
Write-Host "[imgui] Building..."

$p = Start-Process -FilePath $msbuildExe `
    -ArgumentList @(
        "`"$slnFile`"",
        "/p:Configuration=Release",
        "/p:Platform=x64",
        "/m",
        "/v:minimal",
        "/nologo"
    ) `
    -NoNewWindow -Wait -PassThru

if ($p.ExitCode -ne 0) {
    Write-Host "[imgui] MSBuild failed with exit code $($p.ExitCode)" -ForegroundColor Red
    exit $p.ExitCode
}

# MSBuild places the output under bin/Release/. Move it to the binding
# directory.
$builtLib = Join-Path $imguiDir "build\make\windows\bin\Release\imgui_windows_x64.lib"
if (-not (Test-Path $builtLib)) {
    # Try alternate output path layout.
    $alt = Get-ChildItem (Join-Path $imguiDir "build") -Recurse -Filter "imgui_windows_x64.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($alt) { $builtLib = $alt.FullName }
}

if (-not (Test-Path $builtLib)) {
    Write-Host "[imgui] ERROR: built lib not found (looked for $builtLib)" -ForegroundColor Red
    exit 1
}

Copy-Item -Path $builtLib -Destination $outLib -Force
$size = (Get-Item $outLib).Length
Write-Host "[imgui] OK: $outLib ($size bytes)" -ForegroundColor Green
exit 0
