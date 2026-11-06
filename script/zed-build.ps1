#Requires -Version 5.1
<#
.SYNOPSIS
    Runs cargo for the Zed repo inside a Visual Studio developer environment
    whose MSVC toolset ships the Spectre-mitigated CRT libs.

.DESCRIPTION
    `msvc_spectre_libs` (pulled in through `pet` -> `languages` -> `zed`) probes
    for `cl.exe`, derives `<toolset>\lib\spectre\<arch>` from it, and panics when
    that directory is missing. `find-msvc-tools` only probes the environment when
    `VCINSTALLDIR` is set; otherwise it enumerates VS instances over COM in an
    undefined order and takes the first instance that has the tool, which on a
    machine with both VS Community and VS Build Tools can select a Community
    toolset installed without the Spectre component.

    This script imports the environment emitted by the `vcvars64.bat` of a VS
    installation whose toolset actually has the Spectre libs, so the environment
    branch wins, and then forwards every remaining argument to cargo.

.PARAMETER LinkSpectre
    Do not build. Create `lib\spectre` directory junctions in toolsets that lack
    them, borrowing the directory from a same-version toolset in another VS
    installation. Requires an elevated shell. After this, plain `cargo build`
    works from any shell.

.PARAMETER VsPath
    Only consider this Visual Studio installation path.

.PARAMETER Quiet
    Do not print the selected toolset.

.EXAMPLE
    zed-build

.EXAMPLE
    zed-build check -p zed

.EXAMPLE
    zed-build test -p languages --lib

.EXAMPLE
    zed-build -LinkSpectre
#>

$cargoArgs    = @()
$linkSpectre  = $false
$quiet        = $false
$forcedVsPath = $null

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]
    switch ($arg) {
        '-LinkSpectre' { $linkSpectre  = $true; continue }
        '-Quiet'       { $quiet        = $true; continue }
        '-VsPath'      { $forcedVsPath = [string]$args[++$i]; continue }
        default        { $cargoArgs   += $arg }
    }
}

function Get-VisualStudioInstalls {
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not $programFilesX86) { $programFilesX86 = $env:ProgramFiles }

    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return @() }

    $json = & $vswhere -all -products * -format json -utf8 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }

    $raw = ($json -join "`n").Trim()
    if (-not $raw) { return @() }

    return @(($raw | ConvertFrom-Json) | ForEach-Object { $_.installationPath })
}

function Get-DevEnvironment {
    param([string]$VcvarsPath)

    $dump = & cmd.exe /c "call `"$VcvarsPath`" >nul 2>&1 && set" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    $map = @{}
    foreach ($line in $dump) {
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $map[$line.Substring(0, $eq)] = $line.Substring($eq + 1)
    }

    if ($map.Count -eq 0) { return $null }
    return $map
}

function Get-SpectreLibPath {
    param([hashtable]$DevEnvironment)

    $toolsDir = $DevEnvironment['VCToolsInstallDir']
    $arch     = $DevEnvironment['VSCMD_ARG_TGT_ARCH']
    if (-not $toolsDir -or -not $arch) { return $null }

    $path = Join-Path $toolsDir "lib\spectre\$arch"
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Enable-SpectreJunctions {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Creating junctions under Program Files needs an elevated (Administrator) shell.'
    }

    $toolsets = @{}
    foreach ($install in (Get-VisualStudioInstalls)) {
        $msvcRoot = Join-Path $install 'VC\Tools\MSVC'
        if (-not (Test-Path -LiteralPath $msvcRoot)) { continue }

        foreach ($dir in (Get-ChildItem -LiteralPath $msvcRoot -Directory)) {
            if (-not $toolsets.ContainsKey($dir.Name)) { $toolsets[$dir.Name] = @() }
            $toolsets[$dir.Name] += $dir.FullName
        }
    }

    $created = 0
    foreach ($version in ($toolsets.Keys | Sort-Object)) {
        $paths = $toolsets[$version]
        $donor = $paths |
            Where-Object { Test-Path -LiteralPath (Join-Path $_ 'lib\spectre\x64') } |
            Select-Object -First 1

        if (-not $donor) {
            Write-Warning "MSVC $version has no toolset with Spectre libs on this machine; skipping."
            continue
        }

        $donorSpectre = Join-Path $donor 'lib\spectre'
        foreach ($toolset in $paths) {
            $target = Join-Path $toolset 'lib\spectre'
            if (Test-Path -LiteralPath $target) { continue }

            New-Item -ItemType Junction -Path $target -Target $donorSpectre | Out-Null
            Write-Host "linked   $target"
            Write-Host "      -> $donorSpectre"
            $created++
        }
    }

    Write-Host "$created junction(s) created."
}

if ($linkSpectre) {
    Enable-SpectreJunctions
    if ($cargoArgs.Count -eq 0) { exit 0 }
}

$installs = if ($forcedVsPath) { @($forcedVsPath) } else { Get-VisualStudioInstalls }
$candidates = @()

foreach ($install in $installs) {
    $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) { continue }

    $devEnv = Get-DevEnvironment -VcvarsPath $vcvars
    if (-not $devEnv) { continue }

    $spectre = Get-SpectreLibPath -DevEnvironment $devEnv
    if (-not $spectre) { continue }

    $candidates += [pscustomobject]@{
        Install  = $install
        Vcvars   = $vcvars
        Env      = $devEnv
        Spectre  = $spectre
        Toolset  = $devEnv['VCToolsVersion']
    }
}

# vswhere's order is not meaningful, so pick the newest MSVC toolset explicitly.
$selected = $candidates |
    Sort-Object -Property @{ Expression = { try { [version]$_.Toolset } catch { [version]'0.0.0' } } } -Descending |
    Select-Object -First 1

if (-not $selected) {
    Write-Warning 'No VS toolset with Spectre-mitigated libs found; using the current environment.'
    if ($cargoArgs.Count -eq 0) { $cargoArgs = @('build') }
    & cargo @cargoArgs
    exit $LASTEXITCODE
}

foreach ($entry in $selected.Env.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
}

if (-not $quiet) {
    Write-Host "toolset: $($selected.Env['VCToolsInstallDir'])"
    Write-Host "spectre: $($selected.Spectre)"
}

if ($cargoArgs.Count -eq 0) { $cargoArgs = @('build') }

& cargo @cargoArgs
exit $LASTEXITCODE