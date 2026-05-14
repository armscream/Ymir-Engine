# Asset Converter Build Script for Windows PowerShell
# Compiles and runs the Asset Converter using Odin

$ProjectRoot = Split-Path $PSScriptRoot -Parent
$EditorDir = Join-Path $ProjectRoot "Editor/Asset_Converter"
$OutDir = Join-Path $ProjectRoot "Build"
$ExePath = Join-Path $OutDir "asset_converter.exe"

Write-Host "Building Asset Converter..." -ForegroundColor Cyan

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

& odin build $EditorDir "-out:$ExePath" -debug
if ($LASTEXITCODE -eq 0) {
    Write-Host "Build successful!" -ForegroundColor Green
    Write-Host "Launching Asset Converter..." -ForegroundColor Cyan
    & $ExePath
} else {
    Write-Host "Build failed with error code $LASTEXITCODE" -ForegroundColor Red
}   