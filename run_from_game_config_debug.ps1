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


# Clear the build directory before building
if (Test-Path -Path $OutputDir) {
    Remove-Item -Path $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outPath = Join-Path -Path $OutputDir -ChildPath ($safeGameName + ".exe")

# Build with ODIN_DEBUG defined
& $OdinExe build $AppDir -out:$outPath -define:ODIN_DEBUG=1
if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE"
}

Write-Host "Build succeeded: $outPath"


# Copy the entire Config directory to the output directory
$configSourceDir = Join-Path -Path $AppDir -ChildPath "Config"
$configDestDir = Join-Path -Path $OutputDir -ChildPath "Config"
Copy-Item -Path $configSourceDir -Destination $configDestDir -Recurse -Force

# Copy the entire Levels directory to the output directory
$levelsSourceDir = Join-Path -Path $AppDir -ChildPath "Levels"
$levelsDestDir = Join-Path -Path $OutputDir -ChildPath "Levels"
Copy-Item -Path $levelsSourceDir -Destination $levelsDestDir -Recurse -Force

# Run the built executable from the Build directory
Push-Location $OutputDir
& (Join-Path . (Split-Path $outPath -Leaf))
Pop-Location
