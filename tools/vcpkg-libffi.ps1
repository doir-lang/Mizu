#!/usr/bin/env pwsh
#
# Builds libffi for Windows with vcpkg and stages it as .vcpkg/lib/ffi.lib,
# which is where dub.json's `lflags-windows` and tools/coverage.sh look.
#
# Windows ships no libffi, so vcpkg builds one from source. The default
# triplet links it statically against the *dynamic* CRT, which is what LDC
# builds -betterC executables against. Plain `x64-windows` would leave a DLL
# to copy next to every test and example binary, and, worse, libffi's
# `ffi_type_*` are data symbols: the `extern __gshared` declarations in
# source/mizu/ffi/libffi.d cannot reach those through an import library,
# which has no D equivalent of __declspec(dllimport). `x64-windows-static`
# would instead pull in a second, static CRT.
#
# Usage: tools/vcpkg-libffi.ps1 [-Triplet <triplet>]
[CmdletBinding()]
param([string] $Triplet = 'x64-windows-static-md')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# vcpkg's binary cache: honour whatever location the environment asks for --
# CI points it at a directory it keeps between runs -- but vcpkg refuses to
# start when that directory does not exist, which after a cache miss it will
# not.
if ($env:VCPKG_DEFAULT_BINARY_CACHE) {
	New-Item -ItemType Directory -Force -Path $env:VCPKG_DEFAULT_BINARY_CACHE | Out-Null
}

# The same goes for VCPKG_DOWNLOADS. It matters more than the binary cache
# here: libffi is an autotools port, so vcpkg fetches a private MSYS2 -- some
# forty .pkg.tar.zst packages -- to run ./configure under. Those come from
# repo.msys2.org at exactly the versions the port pins, and the mirror drops
# old versions, so an uncached run is one network hiccup away from failing.
if ($env:VCPKG_DOWNLOADS) {
	New-Item -ItemType Directory -Force -Path $env:VCPKG_DOWNLOADS | Out-Null
}

# GitHub's Windows runners set VCPKG_INSTALLATION_ROOT; a development machine
# more often has VCPKG_ROOT, or vcpkg on PATH. Failing all of those, clone one
# into .vcpkg/vcpkg, alongside the rest of what this script owns.
function Find-Vcpkg {
	$clone = Join-Path $root '.vcpkg/vcpkg'
	foreach ($dir in @($env:VCPKG_ROOT, $env:VCPKG_INSTALLATION_ROOT, $clone)) {
		if ($dir) {
			$exe = Join-Path $dir 'vcpkg.exe'
			if (Test-Path $exe) { return $exe }
		}
	}
	$onPath = Get-Command 'vcpkg' -CommandType Application -ErrorAction SilentlyContinue |
		Select-Object -First 1
	if ($onPath) { return $onPath.Source }
	return $null
}

$vcpkg = Find-Vcpkg
if (-not $vcpkg) {
	$clone = Join-Path $root '.vcpkg/vcpkg'
	Write-Host "No vcpkg found. Cloning one into $clone"
	git clone --depth 1 https://github.com/microsoft/vcpkg.git $clone
	if ($LASTEXITCODE -ne 0) { throw 'could not clone vcpkg' }
	& (Join-Path $clone 'bootstrap-vcpkg.bat') -disableMetrics
	if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed' }
	$vcpkg = Join-Path $clone 'vcpkg.exe'
}

# vcpkg reports a build failure by naming log files rather than by printing
# them, which on a runner is a list of paths to a machine that no longer
# exists. Dump the ones it just wrote, newest first, so the reason travels
# with the failure.
function Show-BuildLogs {
	$blds = Join-Path $root 'vcpkg_installed/vcpkg/blds'
	if (-not (Test-Path $blds)) { return }
	$logs = @(Get-ChildItem -Path $blds -Filter '*.log' -Recurse -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Length -gt 0 } |
		Sort-Object LastWriteTime -Descending |
		Select-Object -First 8)
	foreach ($log in $logs) {
		# ::group:: folds the dump on GitHub Actions and is inert elsewhere.
		Write-Host "::group::$($log.FullName)"
		Get-Content -Path $log.FullName -Tail 80
		Write-Host '::endgroup::'
	}
}

# Manifest mode: the dependency list comes from vcpkg.json in the root rather
# than from the command line, and the build lands in vcpkg_installed/ there
# rather than inside the vcpkg installation, which on a runner is shared and
# may not be writable.
Write-Host "Building libffi with $vcpkg (triplet $Triplet)"
Push-Location $root
try {
	& $vcpkg install --triplet $Triplet
	if ($LASTEXITCODE -ne 0) {
		Show-BuildLogs
		throw "vcpkg install failed for triplet $Triplet"
	}
} finally {
	Pop-Location
}

# `"libs-windows": ["ffi"]` in dub.json asks the linker for ffi.lib, which is
# not necessarily what the port called its output, so stage a copy under that
# exact name and prefer an exact match if the port produced one.
$libDir = Join-Path $root "vcpkg_installed/$Triplet/lib"
$built = @(Get-ChildItem -Path $libDir -Filter '*ffi*.lib' -ErrorAction SilentlyContinue |
	Sort-Object { $_.Name -ne 'ffi.lib' }, Name)
if ($built.Count -eq 0) { throw "vcpkg installed no libffi library under $libDir" }

$staging = Join-Path $root '.vcpkg/lib'
New-Item -ItemType Directory -Force -Path $staging | Out-Null
$staged = Join-Path $staging 'ffi.lib'
Copy-Item $built[0].FullName $staged -Force

Write-Host "Staged $($built[0].Name) as $staged"
