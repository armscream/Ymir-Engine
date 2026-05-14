param(
    [string]$ConfigPath = "App/Config/game.json",
    [string]$AppDir = "App",
    [string]$OutputDir = "Build",
    [string]$OdinExe = "odin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path $PSScriptRoot -Parent

# Resolve paths relative to project root
$ConfigPath = Join-Path $ProjectRoot $ConfigPath
$AppDir = Join-Path $ProjectRoot $AppDir
$OutputDir = Join-Path $ProjectRoot $OutputDir

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

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outPath = Join-Path -Path $OutputDir -ChildPath ($safeGameName + ".exe")

& $OdinExe build $AppDir -out:$outPath -define:ODIN_DEBUG=1
if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE"
}

Write-Host "Build succeeded: $outPath"   