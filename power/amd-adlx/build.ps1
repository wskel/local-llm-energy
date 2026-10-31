# Builds gpupower.exe. Needs Visual Studio (or Build Tools) with the C++ workload, and git.
# Fetches AMD's ADLX SDK headers (MIT) at a pinned commit into .deps/ADLX.
$ErrorActionPreference = 'Stop'
$adlxTag = 'V1.4'
$adlxCommit = '66557d410ce4c463f5f7106597d94f53dd84bc82'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$adlx = Join-Path $root '.deps\ADLX'

if (-not (Test-Path $adlx)) {
    # Windows PowerShell 5 turns native stderr into errors, so relax that for git.
    $ErrorActionPreference = 'Continue'
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch $adlxTag https://github.com/GPUOpen-LibrariesAndSDKs/ADLX.git $adlx 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE) { throw 'git clone of ADLX failed' }
}
$head = git -C $adlx rev-parse HEAD
if ($head -ne $adlxCommit) { throw "ADLX checkout is $head, expected $adlxCommit. Delete .deps/ADLX and retry." }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio C++ tools not found (install Build Tools with "Desktop development with C++").' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'

$src = Join-Path $PSScriptRoot 'gpupower.cpp'
$exe = Join-Path $PSScriptRoot 'gpupower.exe'
$cmd = "call `"$vcvars`" >nul && cd /d `"$PSScriptRoot`" && cl /nologo /EHsc /O2 /std:c++17 /DUNICODE /D_UNICODE " +
       "/I `"$adlx`" `"$src`" `"$adlx\SDK\ADLXHelper\Windows\Cpp\ADLXHelper.cpp`" `"$adlx\SDK\Platform\Windows\WinAPIs.cpp`" /Fe:`"$exe`""
cmd /c $cmd
if ($LASTEXITCODE) { throw 'build failed' }
Remove-Item (Join-Path $PSScriptRoot '*.obj') -ErrorAction SilentlyContinue
Write-Output "built $exe"
