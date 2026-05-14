@echo off
REM Asset Converter Build Script for Windows
REM Compiles the Asset Converter using Odin

setlocal enabledelayedexpansion

echo Building Asset Converter...

REM Build the asset converter
odin build "./Editor/Asset_Converter" -out:./Build/asset_converter.exe -debug

if %ERRORLEVEL% EQU 0 (
    echo Build successful! Running Asset Converter...
    .\Build\asset_converter.exe
) else (
    echo Build failed with error code %ERRORLEVEL%
    pause
)

endlocal
