param(
    [string]$EditorDir = "Editor",
    [string]$OutPath = "Build/Editor.exe",
    [string]$OdinExe = "odin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-RunningEditorExe {
    param([string]$ExePath)

    $targetPath = [System.IO.Path]::GetFullPath($ExePath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($targetPath)
    $running = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -ieq $targetPath)
    }

    if (-not $running) {
        return
    }

    Write-Host "Stopping running editor process to avoid file lock..."
    $running | Stop-Process -Force
    $running | Wait-Process -Timeout 5
}

$root = $PSScriptRoot
Set-Location $root
$imguiLibDir = Join-Path -Path $root -ChildPath "Engine/Libs/imgui"
$imguiLibPath = Join-Path -Path $imguiLibDir -ChildPath "imgui_windows_x64.lib"

if (-not (Test-Path -LiteralPath $imguiLibPath)) {
    throw "ImGui static library not found: $imguiLibPath"
}

Write-Host "Building editor from: $EditorDir"
Write-Host "Output executable: $OutPath"

$outDir = Split-Path -Parent $OutPath
if ([string]::IsNullOrWhiteSpace($outDir)) {
    $outDir = "."
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$exe = Join-Path $root $OutPath
Stop-RunningEditorExe -ExePath $exe

# Compile shaders first
$shaderSourceDir = Join-Path -Path $root -ChildPath "Engine/Backend/Vulkan/shaders/source"
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

& $OdinExe build $EditorDir "-out:$OutPath" "-extra-linker-flags:/LIBPATH:`"$imguiLibDir`" imgui_windows_x64.lib /LIBPATH:`"C:\VulkanSDK\1.4.341.1\Lib`" vulkan-1.lib"
if ($LASTEXITCODE -ne 0) {
    throw "Odin build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "Expected editor executable not found: $exe"
}

Write-Host "Editor build complete: $exe"
