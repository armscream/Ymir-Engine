param(
    [string]$ConfigPath = "App/Config/game.json",
    [string]$AppDir = "App",
    [string]$OutputDir = "Build",
    [string]$OdinExe = "odin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path -Path $PSScriptRoot -ChildPath $Path)
}

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

${configFullPath} = Resolve-ProjectPath -Path $ConfigPath
${appDirFullPath} = Resolve-ProjectPath -Path $AppDir
${outputDirFullPath} = Resolve-ProjectPath -Path $OutputDir

if (-not (Test-Path -LiteralPath $configFullPath)) {
    throw "Config file not found: $configFullPath"
}

$cfg = Get-Content -LiteralPath $configFullPath -Raw | ConvertFrom-Json
$gameName = [string]$cfg.game_name
$safeGameName = Get-SafeFileName -Name $gameName
$exePath = Join-Path -Path $outputDirFullPath -ChildPath ($safeGameName + ".exe")

& "$PSScriptRoot/build_from_game_config.ps1" -ConfigPath $configFullPath -AppDir $appDirFullPath -OutputDir $outputDirFullPath -OdinExe $OdinExe
if ($LASTEXITCODE -ne 0) {
    throw "Build script failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $exePath)) {
    throw "Expected executable not found after build: $exePath"
}

if (-not (Test-Path -LiteralPath $appDirFullPath)) {
    throw "App directory not found: $appDirFullPath"
}

Write-Host "Running: $exePath"
Push-Location $appDirFullPath
try {
    & $exePath
}
finally {
    Pop-Location
}
