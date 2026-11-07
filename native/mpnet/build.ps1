# Compila mpnet.dll com o MSVC do Visual Studio 2022 (x64, release, CRT estatico).
# Uso: powershell -ExecutionPolicy Bypass -File native\mpnet\build.ps1
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$out = Join-Path $here "build"
New-Item -ItemType Directory -Force $out | Out-Null

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere nao encontrado; instale o Visual Studio 2022 com C++" }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "Visual Studio com ferramentas C++ x64 nao encontrado" }
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"

$src = Join-Path $here "mpnet.cpp"
$cmd = "`"$vcvars`" >nul && cl /nologo /std:c++17 /O2 /MT /EHsc /W4 /permissive- /LD `"$src`" " +
       "/Fo`"$out\\`" /Fe`"$out\mpnet.dll`" /link /NOLOGO kernel32.lib user32.lib"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw "falha na compilacao ($LASTEXITCODE)" }
Get-Item (Join-Path $out "mpnet.dll") | Select-Object FullName, Length, LastWriteTime
(Get-FileHash (Join-Path $out "mpnet.dll") -Algorithm SHA256).Hash
