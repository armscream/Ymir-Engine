@echo off
REM build_meshopt.bat
REM Compiles zeux/meshoptimizer C++ source into a Windows static lib
REM that the Bifrost asset_converter links against.
REM
REM Usage:  build_meshopt.bat <obj_dir> <out_lib>
REM
REM Requires MSVC Build Tools (cl.exe + lib.exe). Run from a shell
REM where vcvars64.bat has already been sourced.

setlocal
set SRC_DIR=%~dp0..\..\Engine\src\dependencies\meshoptimizer\src
set OBJ_DIR=%~1
set OUT_LIB=%~2

if "%OBJ_DIR%"=="" set OBJ_DIR=Project\bin\Tools\meshopt_obj
if "%OUT_LIB%"=="" set OUT_LIB=Engine\src\dependencies\meshoptimizer\meshoptimizer.lib

if not exist "%OBJ_DIR%" mkdir "%OBJ_DIR%"

echo [meshopt] Compiling *.cpp -> %OBJ_DIR%\
pushd "%SRC_DIR%" >nul
cl /c /EHsc /O2 /Ob2 /std:c++17 /MD /nologo /Fo:"%~dp0..\..\%OBJ_DIR%\\" *.cpp
set ERR=%ERRORLEVEL%
popd >nul
if not %ERR%==0 (
    echo [meshopt] cl.exe failed with exit code %ERR%
    exit /b %ERR%
)

echo [meshopt] Packing objects -> %OUT_LIB%
lib /OUT:"%~dp0..\..\%OUT_LIB%" /NOLOGO "%~dp0..\..\%OBJ_DIR%\*.obj"
set ERR=%ERRORLEVEL%
if not %ERR%==0 (
    echo [meshopt] lib.exe failed with exit code %ERR%
    exit /b %ERR%
)

echo [meshopt] OK: %OUT_LIB%
exit /b 0
