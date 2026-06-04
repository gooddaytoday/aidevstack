# Shared helpers for the Windows Pester suite. Dot-sourced from each *.Tests.ps1 BeforeAll.
# Mirrors the isolation approach of the Linux tests (XDG_CONFIG_HOME=$tmp ... --dry-run):
# subprocess invocations get APPDATA/LOCALAPPDATA/ZED_SECURE_HOSTS_PATH redirected to a temp dir.

$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ScriptsDir = Join-Path $RepoRoot 'scripts\windows'
$ModulePath = Join-Path $ScriptsDir 'ZedSecuritySettings.psm1'

function Get-PwshExe {
    if ($PSVersionTable.PSEdition -eq 'Core') { return 'pwsh' }
    return 'powershell'
}

# Run one of the scripts under scripts/windows as a child process, with optional env overrides.
# Returns @{ Output = <merged stdout+stderr string>; ExitCode = <int> }.
function Invoke-ZedScript {
    param(
        [string]$Script,
        [string[]]$Arguments = @(),
        [hashtable]$EnvVars = @{}
    )
    $exe = Get-PwshExe
    $scriptPath = Join-Path $ScriptsDir $Script
    $saved = @{}
    foreach ($k in $EnvVars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $EnvVars[$k])
    }
    try {
        $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $Arguments
        $out = (& $exe @allArgs 2>&1 | Out-String)
        return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    } finally {
        foreach ($k in $EnvVars.Keys) {
            [Environment]::SetEnvironmentVariable($k, $saved[$k])
        }
    }
}

# Build an isolated APPDATA/LOCALAPPDATA/hosts layout under $Root and (optionally) a stub Zed.exe
# so real-mode installs resolve a "Zed binary" without winget/admin.
function New-ZedTestEnv {
    param([string]$Root, [switch]$SeedZed)
    $appdata = Join-Path $Root 'AppData\Roaming'
    $local = Join-Path $Root 'AppData\Local'
    New-Item -ItemType Directory -Force -Path (Join-Path $appdata 'Zed') | Out-Null
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    if ($SeedZed) {
        $zedDir = Join-Path $local 'Programs\Zed'
        New-Item -ItemType Directory -Force -Path $zedDir | Out-Null
        Set-Content -LiteralPath (Join-Path $zedDir 'Zed.exe') -Value '' -NoNewline
    }
    return @{
        APPDATA               = $appdata
        LOCALAPPDATA          = $local
        ZED_SECURE_HOSTS_PATH = (Join-Path $Root 'hosts')
    }
}

function Get-ZedSettingsPath {
    param([hashtable]$EnvVars)
    return (Join-Path (Join-Path $EnvVars.APPDATA 'Zed') 'settings.json')
}

# Assert that a string contains a literal substring (regex-escaped).
function Should-ContainText {
    param([string]$Haystack, [string]$Needle)
    if (-not ($Haystack -match [regex]::Escape($Needle))) {
        throw "Expected output to contain '$Needle'.`nGot:`n$Haystack"
    }
}

function Should-NotContainText {
    param([string]$Haystack, [string]$Needle)
    if ($Haystack -match [regex]::Escape($Needle)) {
        throw "Expected output NOT to contain '$Needle'.`nGot:`n$Haystack"
    }
}
