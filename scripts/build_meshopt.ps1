# scripts/build_meshopt.ps1
# Compiles zeux/meshoptimizer C++ source into a Windows static lib
# that the Bifrost asset_converter links against.
#
# Requires MSVC Build Tools (cl.exe + lib.exe). The script sources
# vcvars64.bat and inherits its environment.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/build_meshopt.ps1

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    Write-Host "[meshopt] ERROR: vcvars64.bat not found at $vcvars" -ForegroundColor Red
    exit 1
}

$srcDir  = Join-Path $repoRoot "Engine\src\dependencies\meshoptimizer\src"
$objDir  = Join-Path $repoRoot "Project\bin\Tools\meshopt_obj"
$outLib  = Join-Path $repoRoot "Engine\src\dependencies\meshoptimizer\meshoptimizer.lib"

if (-not (Test-Path $srcDir)) {
    Write-Host "[meshopt] ERROR: source dir not found: $srcDir" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $objDir)) { New-Item -ItemType Directory -Path $objDir | Out-Null }

$cppFiles = @(Get-ChildItem -Path $srcDir -Filter "*.cpp" | Select-Object -ExpandProperty FullName)
if ($cppFiles.Count -eq 0) {
    Write-Host "[meshopt] ERROR: no .cpp files found in $srcDir" -ForegroundColor Red
    exit 1
}

Write-Host "[meshopt] Found $($cppFiles.Count) source files"
Write-Host "[meshopt] Output lib: $outLib"

# ------------------------------------------------------------------------
# Run vcvars64.bat and harvest its environment into the current PS
# process. This is the trick that makes the rest of the script work
# without launching a child cmd.exe shell.
# ------------------------------------------------------------------------
Write-Host "[meshopt] Loading MSVC environment from vcvars64.bat..."

$vcvarsCmd = "`"$vcvars`" >nul && set"
$envLines = & cmd.exe /c $vcvarsCmd
foreach ($line in $envLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        $name  = $matches[1]
        $value = $matches[2]
        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

# Confirm cl.exe is now on PATH.
$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $cl) {
    Write-Host "[meshopt] ERROR: cl.exe still not on PATH after vcvars64" -ForegroundColor Red
    exit 1
}
Write-Host "[meshopt] cl.exe: $($cl.Source)"

# ------------------------------------------------------------------------
# Compile. Use a response file so MSVC receives one argument per
# source file regardless of paths containing spaces.
# ------------------------------------------------------------------------
Write-Host "[meshopt] cl.exe compiling $($cppFiles.Count) .cpp files..."

$rspFile = Join-Path $objDir "_cl.rsp"
$rspLines = @(
    "/c"
    "/EHsc"
    "/O2"
    "/Ob2"
    "/std:c++17"
    "/MD"
    "/nologo"
)
$rspLines += "/Fo`"$objDir\\`""
$rspLines += $cppFiles | ForEach-Object { '"' + $_ + '"' }
Set-Content -Path $rspFile -Value ($rspLines -join "`r`n") -Encoding ASCII

$p = Start-Process -FilePath "cl.exe" `
    -ArgumentList "@`"$rspFile`"" `
    -WorkingDirectory $srcDir `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput "$objDir\cl_stdout.log" `
    -RedirectStandardError  "$objDir\cl_stderr.log"

if ($p.ExitCode -ne 0) {
    Write-Host "[meshopt] cl.exe failed with exit code $($p.ExitCode)" -ForegroundColor Red
    if (Test-Path "$objDir\cl_stderr.log") {
        Get-Content "$objDir\cl_stderr.log" -Tail 30
    }
    if (Test-Path "$objDir\cl_stdout.log") {
        Write-Host "--- stdout (last 20 lines) ---"
        Get-Content "$objDir\cl_stdout.log" -Tail 20
    }
    exit $p.ExitCode
}

# ------------------------------------------------------------------------
# Pack. Use a response file too.
# ------------------------------------------------------------------------
$objFiles = @(Get-ChildItem -Path $objDir -Filter "*.obj" | Select-Object -ExpandProperty FullName)
if ($objFiles.Count -eq 0) {
    Write-Host "[meshopt] ERROR: no .obj files produced" -ForegroundColor Red
    exit 1
}

Write-Host "[meshopt] lib.exe packing $($objFiles.Count) objects -> $outLib ..."

$libRsp = Join-Path $objDir "_lib.rsp"
$libRspLines = @(
    "/OUT:`"$outLib`""
    "/NOLOGO"
)
$libRspLines += $objFiles | ForEach-Object { '"' + $_ + '"' }
Set-Content -Path $libRsp -Value ($libRspLines -join "`r`n") -Encoding ASCII

$p = Start-Process -FilePath "lib.exe" `
    -ArgumentList "@`"$libRsp`"" `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput "$objDir\lib_stdout.log" `
    -RedirectStandardError  "$objDir\lib_stderr.log"

if ($p.ExitCode -ne 0) {
    Write-Host "[meshopt] lib.exe failed with exit code $($p.ExitCode)" -ForegroundColor Red
    if (Test-Path "$objDir\lib_stderr.log") {
        Get-Content "$objDir\lib_stderr.log" -Tail 30
    }
    exit $p.ExitCode
}

$size = (Get-Item $outLib).Length
Write-Host "[meshopt] OK: $outLib ($size bytes, $($objFiles.Count) objects)" -ForegroundColor Green
exit 0
