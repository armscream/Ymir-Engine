param(
    [string]$EditorDir = "Editor",
    [string]$OutPath = "Build/Editor.exe",
    [string]$RunWorkingDir = "App",
    [string]$OdinExe = "odin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir

$EditorDir = Join-Path $ProjectRoot $EditorDir
$OutPath = Join-Path $ProjectRoot $OutPath
if (![System.IO.Path]::IsPathRooted($RunWorkingDir)) {
    $RunWorkingDir = Join-Path $ProjectRoot $RunWorkingDir
}

function Resolve-OdinDist {
    param([string]$OdinCommand)
    $odinCmd = Get-Command $OdinCommand -ErrorAction Stop
    return Split-Path -Parent $odinCmd.Source
}   

function Copy-SdlRuntimeDlls {
    param([string]$OdinDist, [string]$OutputDirectory)
    $dlls = @()
    $sdlCoreDll = Join-Path $OdinDist "vendor/sdl3/SDL3.dll"
    if (Test-Path -LiteralPath $sdlCoreDll) { $dlls += $sdlCoreDll }
    else { Write-Warning "Runtime DLL not found: $sdlCoreDll" }

    $imageDllDir = Join-Path $OdinDist "vendor/sdl3/image"
    if (Test-Path -LiteralPath $imageDllDir) {
        $imageDlls = Get-ChildItem -LiteralPath $imageDllDir -Filter "*.dll" -File
        foreach ($dll in $imageDlls) { $dlls += $dll.FullName }
    } else { Write-Warning "Runtime DLL directory not found: $imageDllDir" }

    foreach ($dll in $dlls) {
        Copy-Item -LiteralPath $dll -Destination $OutputDirectory -Force
        Write-Host "Staged runtime: $([System.IO.Path]::GetFileName($dll))"
    }
}

function Stop-RunningEditorExe {
    param([string]$ExePath)
    $targetPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExePath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($targetPath)
    $running = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_.Path) -ieq $targetPath)
    }
    if ($running) {
        Write-Host "Stopping running editor process to avoid file lock..."
        $running | Stop-Process -Force
        $running | Wait-Process -Timeout 5
    }
}

Set-Location $ProjectRoot
$imguiLibDir = Join-Path $ProjectRoot "Engine/Libs/imgui"
$imguiLibPath = Join-Path $imguiLibDir "imgui_windows_x64.lib"

$meshoptLibDir = Join-Path $ProjectRoot "Engine/Libs/meshoptimizer"
$meshoptLibPath = Join-Path $meshoptLibDir "meshoptimizer_windows_x86_64.lib"

$imguizmoLibDir = Join-Path $ProjectRoot "Engine/Libs/imguizmo"
$imguizmoLibPath = Join-Path $imguizmoLibDir "imguizmo_windows_x64.lib"

foreach ($path in @($imguiLibPath, $meshoptLibPath, $imguizmoLibPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required library not found: $path"
    }
}

Write-Host "Building editor from: $EditorDir"
Write-Host "Output executable: $OutPath"

$outDir = Split-Path -Parent $OutPath
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$exe = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
Stop-RunningEditorExe -ExePath $exe

$odinDist = Resolve-OdinDist -OdinCommand $OdinExe
Write-Host "Using Odin dist: $odinDist"

$shaderSourceDir = Join-Path $ProjectRoot "Engine/Backend/Vulkan/shaders/source"
if (Test-Path -LiteralPath $shaderSourceDir) {
    Write-Host "Compiling shaders..."
    Push-Location $shaderSourceDir
    & .\compile.bat
    Pop-Location
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Shader compilation had warnings or errors, but continuing..."
    }
} else {
    Write-Warning "Shader source directory not found: $shaderSourceDir"
}

& $OdinExe build $EditorDir "-out:$OutPath" "-debug" "-define:ODIN_DEBUG=true" "-extra-linker-flags:/LIBPATH:`"$imguiLibDir`" imgui_windows_x64.lib /LIBPATH:`"$meshoptLibDir`" meshoptimizer_windows_x86_64.lib /LIBPATH:`"$imguizmoLibDir`" imguizmo_windows_x64.lib /LIBPATH:`"C:\VulkanSDK\1.4.341.1\Lib`" vulkan-1.lib"
if ($LASTEXITCODE -ne 0) {
    throw "Odin build failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "Expected editor executable not found: $exe"
}

Copy-SdlRuntimeDlls -OdinDist $odinDist -OutputDirectory (Split-Path -Parent $exe)

$runCwd = $RunWorkingDir
if (-not (Test-Path -LiteralPath $runCwd)) {
    throw "Run working directory not found: $runCwd"
}

Write-Host "Launching editor: $exe"
Write-Host "Run working directory: $runCwd"
Push-Location $runCwd
try {
    & $exe
} finally {
    Pop-Location
}   