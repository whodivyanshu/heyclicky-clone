# Builds Jarvis for Windows from the repository root: the Swift bridge, then the app, then the installer.
# Needs Swift 6.4 and the .NET 10 SDK. The installer also needs Inno Setup, and is skipped without it.
#   windows\scripts\build.ps1
param([switch]$NoInstaller)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$native = Join-Path $root 'windows\native'
$dist = Join-Path $root 'windows\dist'
Set-Location $root

Write-Host '== Building the Swift bridge'
swift build -c release --product JarvisBridge
if ($LASTEXITCODE -ne 0) { throw 'The Swift build failed.' }

Write-Host '== Collecting what the bridge needs to run'
Remove-Item $native -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $native | Out-Null
Copy-Item (Join-Path $root '.build\release\JarvisBridge.dll') $native

# The Swift runtime, from wherever the toolchain put it on PATH.
$swiftCore = (Get-Command swiftCore.dll -ErrorAction Stop).Source
Copy-Item (Join-Path (Split-Path $swiftCore) '*.dll') $native

# Visual C++ runtime, so a PC without the redistributable still works.
foreach ($dll in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
    Copy-Item (Join-Path $env:SystemRoot "System32\$dll") $native
}

Write-Host '== Building the app'
Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
dotnet publish (Join-Path $root 'windows\Jarvis\Jarvis.csproj') -c Release -o (Join-Path $dist 'Jarvis')
if ($LASTEXITCODE -ne 0) { throw 'The app build failed.' }

$iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
if (-not $NoInstaller -and (Test-Path $iscc)) {
    Write-Host '== Building the installer'
    & $iscc (Join-Path $root 'windows\installer\Jarvis.iss')
    if ($LASTEXITCODE -ne 0) { throw 'The installer build failed.' }
    Write-Host "Installer: $dist\Jarvis-Setup.exe"
} else {
    Write-Host "Skipped the installer. To run it directly: $dist\Jarvis\Jarvis.exe"
}
