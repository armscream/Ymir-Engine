param(
    [string]$EditorDir = "Editor",
    [string]$OutPath = "Build/Editor.exe",
    [string]$OdinExe = "odin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
Set-Location $root

New-Item -ItemType Directory -Path "Build" -Force | Out-Null

& $OdinExe build $EditorDir "-out:$OutPath"
if ($LASTEXITCODE -ne 0) {
    throw "Odin build failed with exit code $LASTEXITCODE"
}

$exe = Join-Path $root $OutPath
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Expected editor executable not found: $exe"
}

& $exe
