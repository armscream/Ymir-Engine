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

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outPath = Join-Path -Path $OutputDir -ChildPath ($safeGameName + ".exe")

Write-Host "Game name from config: $gameName"
Write-Host "Output executable: $outPath"

$odinArgs = @(
    "build",
    $AppDir,
    "-out:$outPath"
)

& $OdinExe @odinArgs
if ($LASTEXITCODE -ne 0) {
    throw "Odin build failed with exit code $LASTEXITCODE"
}

Write-Host "Build complete: $outPath"
