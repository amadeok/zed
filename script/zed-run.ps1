#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the Zed repo when needed and runs the local Zed executable.

.DESCRIPTION
    By default this runs `target\debug\zed.exe` and forwards all remaining
    arguments to Zed. If the executable does not exist, it is built first with
    `zed-build` so the same Visual Studio/Spectre environment is used.

    Pass `-Release` to use `target\release\zed.exe`. Pass `-Build` to force a
    rebuild before running, or run `zed-build` yourself and then use `zed-run`.

    Use `--` to stop parsing zed-run options and pass the rest to Zed.

.PARAMETER Release
    Run the release build instead of the debug build.

.PARAMETER Build
    Build before running, even if the executable already exists.

.PARAMETER VsPath
    Only consider this Visual Studio installation path when building.

.PARAMETER Quiet
    Do not print the selected toolset when building.

.EXAMPLE
    zed-run

.EXAMPLE
    zed-run -Release

.EXAMPLE
    zed-run -Build

.EXAMPLE
    zed-run C:\path\to\file.txt

.EXAMPLE
    zed-run -- --help
#>

$zedArgs      = @()
$release      = $false
$forceBuild   = $false
$quiet        = $false
$forcedVsPath = $null
$parseOptions = $true

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]

    if ($parseOptions -and $arg -eq '--') {
        $parseOptions = $false
        continue
    }

    if ($parseOptions) {
        switch ($arg) {
            '-Release'  { $release      = $true; continue }
            '--release' { $release      = $true; continue }
            '-Build'    { $forceBuild   = $true; continue }
            '--build'   { $forceBuild   = $true; continue }
            '-Quiet'    { $quiet        = $true; continue }
            '-VsPath'   { $forcedVsPath = [string]$args[++$i]; continue }
        }
    }

    $zedArgs += $arg
}

$repoRoot   = Split-Path -Parent $PSScriptRoot
$profile    = if ($release) { 'release' } else { 'debug' }
$binaryPath = Join-Path $repoRoot "target\$profile\zed.exe"

if ($forceBuild -or -not (Test-Path -LiteralPath $binaryPath)) {
    $buildArgs = @()
    if ($forcedVsPath) { $buildArgs += @('-VsPath', $forcedVsPath) }
    if ($quiet)        { $buildArgs += '-Quiet' }
    $buildArgs += 'build'
    if ($release)      { $buildArgs += '--release' }

    & (Join-Path $PSScriptRoot 'zed-build.cmd') @buildArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not (Test-Path -LiteralPath $binaryPath)) {
    Write-Error "Zed executable not found at $binaryPath. Build it with script\zed-build.cmd first."
    exit 1
}

& $binaryPath @zedArgs
exit $LASTEXITCODE