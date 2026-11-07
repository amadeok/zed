<#
.SYNOPSIS
    Single entry point for building and running the Zed repo on Windows.

.DESCRIPTION
    Runs cargo for the Zed repo inside a Visual Studio developer environment
    whose MSVC toolset ships the Spectre-mitigated CRT libs, and runs the
    built zed.exe. `zed.cmd` is a thin shim that invokes this script with
    `-ExecutionPolicy Bypass`, so the same entry point works from cmd.exe,
    PowerShell, and a double-click.

    Why the VS environment dance: `msvc_spectre_libs` (pulled in through
    `pet` -> `languages` -> `zed`) probes for `cl.exe`, derives
    `<toolset>\lib\spectre\<arch>` from it, and panics when that directory
    is missing. `find-msvc-tools` only probes the environment when
    `VCINSTALLDIR` is set; otherwise it enumerates VS instances over COM in an
    undefined order and takes the first instance that has the tool, which on a
    machine with both VS Community and VS Build Tools can select a Community
    toolset installed without the Spectre component.

    This script imports the environment emitted by the `vcvars64.bat` of a VS
    installation whose toolset actually has the Spectre libs, so the
    environment branch wins, and then forwards every remaining argument to
    cargo.

    Modes:

    - build mode (default): every argument is forwarded to cargo. With no
      arguments, runs `cargo build` (debug profile). The first positional
      argument may also be a cargo command, e.g. `zed check -p zed`.
    - run mode (`zed run ...`): runs `target\<profile>\zed.exe`, building it
      first when it is missing (or when `-Build` is passed). All non-option
      arguments are forwarded to zed.exe.

    Options are only consumed before `--`; everything from `--` on is
    forwarded verbatim.

.PARAMETER Release
    Use the release profile instead of debug, both when building and when
    running.

.PARAMETER Build
    (run mode) Build before running, even if the executable already exists.

.PARAMETER LinkSpectre
    (build mode) Do not build. Create `lib\spectre` directory junctions in
    toolsets that lack them, borrowing the directory from a same-version
    toolset in another VS installation. Requires an elevated shell. After
    this, plain `cargo build` works from any shell.

.PARAMETER VsPath
    Only consider this Visual Studio installation path.

.PARAMETER Quiet
    Do not print the selected toolset.

.PARAMETER Stable
    Set ZED_RELEASE_CHANNEL=stable for cargo and for the process launched by
    run mode. Release builds embed the channel at compile time, so combine
    this with -Release to build a stable-channel binary; debug builds read
    the variable at runtime.

.PARAMETER Help
    Show this help and exit.

.EXAMPLE
    zed

    Runs `cargo build` (debug profile).

.EXAMPLE
    zed -Release

    Runs `cargo build --release`.

.EXAMPLE
    zed -Stable -Release

    Runs `cargo build --release` with ZED_RELEASE_CHANNEL=stable: the binary
    uses the stable channel and shares its single-instance mutex and named
    pipe with an installed stable Zed.

.EXAMPLE
    zed check -p zed

    Runs `cargo check -p zed` inside the selected VS environment.

.EXAMPLE
    zed -Quiet test -p debugger_ui --lib stack_frame_list

    Runs the matching cargo test without printing the selected toolset.

.EXAMPLE
    zed run

    Runs `target\debug\zed.exe`, building it first if it does not exist.

.EXAMPLE
    zed run -Release

    Runs `target\release\zed.exe`, building it first if it does not exist.

.EXAMPLE
    zed run -Build C:\path\to\file.txt

    Rebuilds, then opens the given file.

.EXAMPLE
    zed run --foreground --user-data-dir C:\some\dir C:\some\project

    Forwards `--foreground`, `--user-data-dir`, and the project path to
    zed.exe; none of them are options of this script.

.EXAMPLE
    zed -LinkSpectre

    Creates Spectre library junctions instead of building. Requires an
    elevated shell.
#>

#Requires -Version 5.1

$mode         = 'cargo' # 'cargo' or 'run'
$release      = $false
$forceBuild   = $false
$linkSpectre  = $false
$quiet        = $false
$stable       = $false
$showHelp     = $false
$forcedVsPath = $null
$parseOptions = $true
$cargoArgs    = @()
$zedArgs      = @()

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]

    if ($parseOptions -and $arg -eq '--') {
        $parseOptions = $false
        continue
    }

    # Note: `continue` inside a `switch` case only ends the case, it does not
    # continue this loop, so options are tracked with a flag instead.
    $consumed = $true
    if ($parseOptions) {
        switch ($arg) {
            '-Release'     { $release      = $true }
            '--release'    { $release      = $true }
            '-Stable'      { $stable       = $true }
            '--stable'     { $stable       = $true }
            '-Build'       { $forceBuild   = $true }
            '--build'      { $forceBuild   = $true }
            '-LinkSpectre' { $linkSpectre  = $true }
            '-Quiet'       { $quiet        = $true }
            '-h'           { $showHelp     = $true }
            '--help'       { $showHelp     = $true }
            '-Help'        { $showHelp     = $true }
            '-VsPath'      { $forcedVsPath = [string]$args[++$i] }
            default        { $consumed     = $false }
        }
    } else {
        $consumed = $false
    }

    if ($consumed) { continue }

    if ($mode -eq 'cargo' -and $cargoArgs.Count -eq 0 -and $arg -eq 'run') {
        $mode = 'run'
        continue
    }

    if ($mode -eq 'cargo') { $cargoArgs += $arg } else { $zedArgs += $arg }
}

function Show-Usage {
    @'
Single entry point for building and running the Zed repo on Windows.

Usage:
  zed [cargo args...]              Run cargo (default: cargo build)
  zed run [options] [zed args...]  Run target\<profile>\zed.exe

Options (only consumed before --):
  -Release, --release   Use the release profile
  -Stable, --stable     Set ZED_RELEASE_CHANNEL=stable
  -Build, --build       (run mode) Build before running
  -LinkSpectre          Create Spectre junctions instead of building
  -VsPath <path>        Only use this Visual Studio installation
  -Quiet                Do not print the selected toolset
  -h, --help, -Help     Show this help
  --                    Forward the rest verbatim

Examples:
  zed                     cargo build (debug)
  zed -Release            cargo build --release
  zed -Stable -Release    stable-channel release build
  zed run -Release        run target\release\zed.exe
'@ | Write-Host
}

if ($showHelp) {
    Show-Usage
    exit 0
}

if ($stable) {
    $env:ZED_RELEASE_CHANNEL = 'stable'
}

if ($linkSpectre -and $mode -eq 'run') {
    Write-Error '-LinkSpectre only applies to build mode.'
    exit 1
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

function Invoke-Cargo {
    param([string[]]$CargoArgs)

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
        & cargo @CargoArgs
        $script:cargoExit = $LASTEXITCODE
        return
    }

    foreach ($entry in $selected.Env.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }

    if (-not $quiet) {
        Write-Host "toolset: $($selected.Env['VCToolsInstallDir'])"
        Write-Host "spectre: $($selected.Spectre)"
    }

    # Cargo writes directly to the console; the exit code is reported via
    # $script:cargoExit so the caller does not have to capture cargo's
    # output.
    & cargo @CargoArgs
    $script:cargoExit = $LASTEXITCODE
}

$repoRoot = Split-Path -Parent $PSScriptRoot

if ($mode -eq 'run') {
    $profile    = if ($release) { 'release' } else { 'debug' }
    $binaryPath = Join-Path $repoRoot "target\$profile\zed.exe"

    if ($forceBuild -or -not (Test-Path -LiteralPath $binaryPath)) {
        $buildCargoArgs = @('build')
        if ($release) { $buildCargoArgs += '--release' }

        Invoke-Cargo $buildCargoArgs
        if ($script:cargoExit -ne 0) { exit $script:cargoExit }
    }

    if (-not (Test-Path -LiteralPath $binaryPath)) {
        Write-Error "Zed executable not found at $binaryPath. Build it with `script\zed.cmd build` first."
        exit 1
    }

    & $binaryPath @zedArgs
    exit $LASTEXITCODE
}

# cargo mode
if ($linkSpectre) {
    Enable-SpectreJunctions
    if ($cargoArgs.Count -eq 0) { exit 0 }
}

if ($cargoArgs.Count -eq 0) { $cargoArgs = @('build') }
if ($release -and $cargoArgs -notcontains '--release') { $cargoArgs += '--release' }

Invoke-Cargo $cargoArgs
exit $script:cargoExit
