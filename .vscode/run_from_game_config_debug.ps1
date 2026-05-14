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

# Debug run: use 'odin run' with ODIN_DEBUG=true in the App directory
Push-Location $AppDir
& $OdinExe run . -define:ODIN_DEBUG=true "-extra-linker-flags:/LIBPATH:`"$imguiLibDir`" imgui_windows_x64.lib /LIBPATH:`"C:\VulkanSDK\1.4.341.1\Lib`" vulkan-1.lib"
Pop-Location
