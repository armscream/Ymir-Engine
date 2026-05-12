param(
    [string]$ConfigPath = "App/Config/game.json",
    [string]$AppDir = "App",
    [string]$OutputDir = "Build",
    [string]$OdinExe = "odin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SafeFileName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "game"
    }

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safeChars = $Name.ToCharArray() | ForEach-Object {
        if ($invalidChars -contains $_) { '_' } else { $_ }
    }

    $safeName = (-join $safeChars).Trim()
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        return "game"
    }

    return $safeName
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$configJson = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$gameName = [string]$configJson.game_name
$safeGameName = Get-SafeFileName -Name $gameName
$imguiLibDir = Join-Path -Path $PSScriptRoot -ChildPath "Engine/Libs/imgui"
$imguiLibPath = Join-Path -Path $imguiLibDir -ChildPath "imgui_windows_x64.lib"

if (-not (Test-Path -LiteralPath $imguiLibPath)) {
    throw "ImGui static library not found: $imguiLibPath"
}


# Clear the build directory before building
if (Test-Path -Path $OutputDir) {
    Remove-Item -Path $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outPath = Join-Path -Path $OutputDir -ChildPath ($safeGameName + ".exe")

Write-Host "Game name from config: $gameName"
Write-Host "Output executable: $outPath"

# Compile shaders first
$shaderSourceDir = Join-Path -Path $PSScriptRoot -ChildPath "Engine/Backend/Vulkan/shaders/source"
if (Test-Path -LiteralPath $shaderSourceDir) {
    Write-Host "Compiling shaders..."
    Push-Location $shaderSourceDir
    & .\compile.bat
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Shader compilation had warnings or errors, but continuing..."
    }
    Pop-Location
} else {
    Write-Warning "Shader source directory not found: $shaderSourceDir"
}

$odinArgs = @(
    "build",
    $AppDir,
    "-out:$outPath",
    "-extra-linker-flags:/LIBPATH:`"$imguiLibDir`" imgui_windows_x64.lib /LIBPATH:`"C:\VulkanSDK\1.4.341.1\Lib`" vulkan-1.lib"
)

& $OdinExe @odinArgs
if ($LASTEXITCODE -ne 0) {
    throw "Odin build failed with exit code $LASTEXITCODE"
}

Write-Host "Build complete: $outPath"
