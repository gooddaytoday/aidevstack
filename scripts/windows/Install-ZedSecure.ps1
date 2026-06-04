#Requires -Version 5.1
<#
.SYNOPSIS
  Privacy-first Zed installer for Windows 11+ with an optional local OpenAI-compatible LLM.
.DESCRIPTION
  Windows port of scripts/install-zed-secure.sh. Enforces a privacy/security settings
  overlay, clears cloud API key environment variables at launch, and (by default for
  local-AI installs) blocks Zed's outbound network traffic except loopback via a
  per-application Windows Defender Firewall rule. See docs/zed-secure-install-windows.md.
.NOTES
  Targets Windows PowerShell 5.1 (preinstalled). Runs under PowerShell 7 too.
#>
[CmdletBinding()]
param(
    [switch]$InstallDeps,
    [switch]$DisableAi,
    [string]$LlmModel = $(if ($env:ZED_LLM_MODEL) { $env:ZED_LLM_MODEL } else { '' }),
    [string]$LlmApiUrl = $(if ($env:ZED_LLM_API_URL) { $env:ZED_LLM_API_URL } else { 'http://127.0.0.1:8080/v1' }),
    [string]$LlmCompletionsUrl = $(if ($env:ZED_LLM_COMPLETIONS_URL) { $env:ZED_LLM_COMPLETIONS_URL } else { '' }),
    [string]$LlmProviderName = $(if ($env:ZED_LLM_PROVIDER_NAME) { $env:ZED_LLM_PROVIDER_NAME } else { 'LocalLLM' }),
    [switch]$DisableLocalEditPredictions,
    [switch]$AllowNonlocalLlm,
    [switch]$EnableNetworkSandbox,
    [switch]$NoNetworkSandbox,
    [switch]$AllowNoSandbox,
    [switch]$EnableEndpointBlocklist,
    [switch]$DisableEndpointBlocklist,
    [switch]$MachineWideStrictFirewall,
    [switch]$IAcceptMachineWideFirewall,
    [switch]$Yes,
    [switch]$DoNotHideEnvFiles,
    [switch]$MergeConfig,
    [switch]$RefreshLlmConfig,
    [switch]$RepairSettings,
    [switch]$RegenerateTemplate,
    [switch]$Offline,
    [switch]$ReplaceZedCli,
    [string]$Channel = $(if ($env:ZED_CHANNEL) { $env:ZED_CHANNEL } else { 'stable' }),
    [string]$ZedVersion = $(if ($env:ZED_VERSION) { $env:ZED_VERSION } else { 'latest' }),
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ZedSecuritySettings.psm1') -Force

# Capture the script-level bound parameters now; inside functions $PSBoundParameters refers
# to that function's own parameters, not the script's.
$script:BoundParameters = $PSBoundParameters

# --- logging helpers (mirror log/warn/die/run) ---

function Write-Log  { param([string]$Message) [Console]::Out.WriteLine("==> $Message") }
function Write-Warn { param([string]$Message) [Console]::Error.WriteLine("WARNING: $Message") }
function Stop-Die   { param([string]$Message) [Console]::Error.WriteLine("ERROR: $Message"); exit 1 }
function Test-Have  { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Run a side-effecting action, or print it under -DryRun (mirror run()).
function Invoke-Step {
    param([string]$Message, [scriptblock]$Action)
    if ($DryRun) {
        [Console]::Out.WriteLine("[dry-run] $Message")
    } else {
        Write-Log "Running: $Message"
        & $Action
    }
}

# --- state (script-scoped so functions share mutable install state) ---

function Initialize-ZedState {
    $script:DisableAi                   = [bool]$DisableAi
    $script:DisableLocalEditPredictions = [bool]$DisableLocalEditPredictions
    $script:DoNotHideEnvFiles           = [bool]$DoNotHideEnvFiles
    $script:LlmModel                    = $LlmModel
    $script:LlmApiUrl                   = $LlmApiUrl
    $script:CompletionsUrl              = $LlmCompletionsUrl
    $script:LlmProviderName             = $LlmProviderName
    $script:AllowNonlocalLlm            = [bool]$AllowNonlocalLlm
    $script:EnableSandbox               = [bool]$EnableNetworkSandbox
    $script:SandboxExplicit             = [bool]$EnableNetworkSandbox
    $script:NoSandbox                   = [bool]$NoNetworkSandbox
    $script:AllowNoSandbox              = [bool]$AllowNoSandbox
    $script:EnableBlocklist             = [bool]$EnableEndpointBlocklist
    $script:DisableBlocklist            = [bool]$DisableEndpointBlocklist
    $script:MachineWide                 = [bool]$MachineWideStrictFirewall
    $script:IAccept                     = [bool]$IAcceptMachineWideFirewall
    $script:Yes                         = [bool]$Yes
    $script:Merge                       = [bool]$MergeConfig
    $script:Refresh                     = [bool]$RefreshLlmConfig
    $script:Repair                      = [bool]$RepairSettings
    $script:Regen                       = [bool]$RegenerateTemplate
    $script:Offline                     = [bool]$Offline
    $script:ReplaceCli                  = [bool]$ReplaceZedCli
    $script:InstallDeps                 = [bool]$InstallDeps
    $script:Channel                     = $Channel
    $script:ZedVersion                  = $ZedVersion
    $script:Uninstall                   = [bool]$Uninstall
    $script:ActionRequested             = $false
    $script:PrivilegedArgs              = @()
    $script:ZedExe                      = ''

    # Paths (config %APPDATA%\Zed, share %LOCALAPPDATA%\zed-secure; overridable via env for tests)
    $appData   = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData\Roaming' }
    $localApp  = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
    $script:ConfigDir              = Join-Path $appData 'Zed'
    $script:Settings              = Join-Path $script:ConfigDir 'settings.json'
    $script:SettingsTemplate      = Join-Path $script:ConfigDir 'settings.zed-secure-template.json'
    $script:ShareDir              = Join-Path $localApp 'zed-secure'
    $script:SettingsTemplateShare = Join-Path $script:ShareDir 'settings-template.json'
    $script:EnforceModuleDest     = Join-Path $script:ShareDir 'ZedSecuritySettings.psm1'
    $script:EnforceHelper         = Join-Path $script:ShareDir 'Enforce-ZedSettings.ps1'
    $script:LauncherPs1           = Join-Path $script:ShareDir 'ZedSecureLauncher.ps1'
    $script:LauncherVbs           = Join-Path $script:ShareDir 'zed-secure.vbs'
    $script:BinDir                = Join-Path $script:ShareDir 'bin'
    $script:ZedSecureCmd          = Join-Path $script:BinDir 'zed-secure.cmd'
    $script:ZedCliShim            = Join-Path $script:BinDir 'zed.cmd'

    $script:HostsPath = if ($env:ZED_SECURE_HOSTS_PATH) {
        $env:ZED_SECURE_HOSTS_PATH
    } elseif ($env:SystemRoot) {
        Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    } else {
        'C:\Windows\System32\drivers\etc\hosts'
    }

    $script:HostsMarkerBegin = '# zed-secure-blocklist begin'
    $script:HostsMarkerEnd   = '# zed-secure-blocklist end'
    $script:BlocklistDomains = @(
        'cloud.zed.dev', 'api2.amplitude.com', 'api.openai.com', 'api.anthropic.com',
        'generativelanguage.googleapis.com', 'api.mistral.ai', 'api.x.ai', 'api.together.xyz',
        'o4505698048008192.ingest.us.sentry.io'
    )
    $script:CloudKeyVars = @(
        'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GOOGLE_API_KEY', 'XAI_API_KEY', 'GEMINI_API_KEY',
        'MISTRAL_API_KEY', 'TOGETHER_AI_API_KEY', 'VERCEL_AI_GATEWAY_API_KEY', 'OLLAMA_API_KEY'
    )
    $script:FirewallGroup       = 'zed-secure'
    $script:FirewallStrictGroup = 'zed-secure-strict'
}

function Show-Usage {
    @'
Usage: Install-ZedSecure.ps1 [OPTIONS]

Privacy-first Zed installer for Windows 11+ with optional local OpenAI-compatible LLM.

Preset installers (simpler entry points):
  Install-ZedNoAi.ps1 [OPTIONS]               -DisableAi preset; OPTIONS forwarded
  Install-ZedLocalLlm.ps1 MODEL [OPTIONS]     local LLM preset (MODEL first); OPTIONS forwarded

Options:
  -InstallDeps                 Verify winget / App Installer is present (Windows: no system packages)
  -DisableAi                   Disable all AI features (disable_ai=true)
  -LlmModel MODEL              Local model name (required unless -DisableAi)
  -LlmApiUrl URL               OpenAI-compatible API URL (default: http://127.0.0.1:8080/v1)
  -LlmCompletionsUrl URL       Completions endpoint for edit predictions
  -LlmProviderName NAME        Provider label in Zed UI (default: LocalLLM)
  -DisableLocalEditPredictions Disable inline edit predictions, keep Agent Panel
  -AllowNonlocalLlm            Allow LLM URL not on loopback (not recommended)
  -EnableNetworkSandbox        Per-app Windows Firewall rule blocking Zed egress except loopback
                               (default for local-AI installs)
  -NoNetworkSandbox            Opt out of network sandbox (not recommended)
  -AllowNoSandbox              Continue if Windows Firewall sandbox is unavailable
  -EnableEndpointBlocklist     Best-effort hosts-file blocklist for cloud endpoints
  -DisableEndpointBlocklist    Remove endpoint blocklist markers
  -MachineWideStrictFirewall   Block ALL outbound traffic for the machine except loopback (dangerous)
  -IAcceptMachineWideFirewall  Required with -MachineWideStrictFirewall (explicit consent)
  -Yes                         Skip confirmation pause for dangerous options
  -DoNotHideEnvFiles           Do not exclude .env from file tree/search
  -MergeConfig                 Full merge: security keys + language_models from template
  -RefreshLlmConfig            Security overlay + overwrite language_models from template
  -RepairSettings              Re-apply privacy overlay only (no Zed reinstall)
  -RegenerateTemplate          With -RepairSettings: overwrite template from parameters (risky)
  -Offline                     Fail if a network fetch is required; use with ZED_BUNDLE_PATH
  -ReplaceZedCli               Repoint the 'zed' command on PATH to the secure launcher (opt-in)
  -Channel CHANNEL             Zed release channel: stable|preview|nightly|dev (default: stable)
  -ZedVersion VERSION          Zed version (default: latest)
  -DryRun                      Print actions without executing
  -Uninstall                   Remove launcher, firewall rule, shortcut patches, blocklist
  -Help                        Show this help

Environment variables:
  ZED_CHANNEL, ZED_VERSION, ZED_BUNDLE_PATH
  ZED_LLM_MODEL, ZED_LLM_API_URL, ZED_LLM_COMPLETIONS_URL, ZED_LLM_PROVIDER_NAME
  ZED_SECURE_ENFORCE_SETTINGS  Set to 0 in the launcher to skip the privacy overlay (default: 1)
  ZED_SECURE_ENFORCE_STRICT    Set to 1 to abort launch if the privacy overlay fails (default: 0)

Examples:
  .\Install-ZedSecure.ps1 -RepairSettings
  .\Install-ZedNoAi.ps1
  .\Install-ZedLocalLlm.ps1 my-model
  .\Install-ZedSecure.ps1 -DisableAi
  .\Install-ZedSecure.ps1 -LlmModel my-model -EnableEndpointBlocklist
  .\Install-ZedSecure.ps1 -Channel preview -DisableAi -DryRun
'@ | ForEach-Object { [Console]::Out.WriteLine($_) }
}

# --- validation ---

function Test-FirewallAcceptFlags {
    if ($script:IAccept -and -not $script:MachineWide) {
        Stop-Die "-IAcceptMachineWideFirewall requires -MachineWideStrictFirewall"
    }
    if ($script:MachineWide -and -not $script:IAccept) {
        Stop-Die "-MachineWideStrictFirewall requires -IAcceptMachineWideFirewall (see -Help)"
    }
}

function Set-LocalAiSandboxDefault {
    if ($script:DisableAi -or -not $script:LlmModel) { return }
    if ($script:NoSandbox -and $script:SandboxExplicit) {
        Stop-Die "Cannot use -EnableNetworkSandbox and -NoNetworkSandbox together"
    }
    if ($script:NoSandbox) {
        $script:EnableSandbox = $false
        Write-Warn "Network sandbox DISABLED. Cloud egress remains possible for Zed processes."
        Write-Warn "This is NOT recommended when working with proprietary code."
        return
    }
    if (-not $script:EnableSandbox) {
        $script:EnableSandbox = $true
        Write-Log "Network sandbox enabled by default for local-AI install"
    }
}

function Set-InstallActionRequested {
    $req = $false
    if ($script:InstallDeps -or $EnableNetworkSandbox -or $script:EnableBlocklist -or
        $script:MachineWide -or $script:Merge -or $script:Refresh -or $script:Offline -or $script:ReplaceCli) { $req = $true }
    if ($script:LlmModel) { $req = $true }
    if ($script:BoundParameters.ContainsKey('Channel') -or $script:Channel -ne 'stable') { $req = $true }
    if ($script:BoundParameters.ContainsKey('ZedVersion') -or $script:ZedVersion -ne 'latest') { $req = $true }
    if ($script:DisableAi -and -not $script:DisableBlocklist) { $req = $true }
    $script:ActionRequested = $req
}

function Test-ZedChannel {
    switch ($script:Channel) {
        'stable'  { return }
        'preview' { return }
        'nightly' { return }
        'dev'     { return }
        default   { Stop-Die "unknown -Channel: $($script:Channel) (allowed: stable, preview, nightly, dev)" }
    }
}

function Get-ZedChannelDirName {
    param([string]$ChannelName)
    switch ($ChannelName) {
        'stable'  { return 'Zed' }
        'preview' { return 'Zed Preview' }
        'nightly' { return 'Zed Nightly' }
        'dev'     { return 'Zed Dev' }
        default   { return 'Zed' }
    }
}

function Get-SyntheticZedExe {
    param([string]$ChannelName)
    $dir = Get-ZedChannelDirName $ChannelName
    $localApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { 'C:\Users\Default\AppData\Local' }
    return (Join-Path (Join-Path $localApp "Programs\$dir") 'Zed.exe')
}

function Test-UrlValid {
    param([string]$Url, [string]$Name)
    if ($Url -match '["\\]') { Stop-Die "invalid characters in ${Name}: quotes or backslashes not allowed" }
    if ($Url -notmatch '^(http|https)://') { Stop-Die "invalid ${Name}: must start with http:// or https://" }
    if ($Url -match '[^A-Za-z0-9._:/\[\]?&=%#-]') { Stop-Die "invalid characters in ${Name}" }
    $rest = $Url -replace '^https?://', ''
    $authority = ($rest -split '/', 2)[0]
    $authority = ($authority -split '\?', 2)[0]
    $authority = ($authority -split '#', 2)[0]
    if ($authority -match '@') { Stop-Die "invalid characters in ${Name}: userinfo (@) not allowed" }
}

function Get-ZedUrlHost {
    param([string]$Url)
    if ($Url -notmatch '^(http|https)://') { return $null }
    $rest = $Url -replace '^https?://', ''
    $authority = ($rest -split '/', 2)[0]
    $authority = ($authority -split '\?', 2)[0]
    $authority = ($authority -split '#', 2)[0]
    if ($authority -match '@') { return $null }
    if ($authority.StartsWith('[')) { return (($authority -split '\]', 2)[0] + ']') }
    if ($authority -match ':') { return ($authority -split ':')[0] }
    if (-not $authority) { return $null }
    return $authority
}

function Test-ZedLoopbackHost {
    param([string]$HostName)
    return (@('127.0.0.1', 'localhost', '[::1]') -contains $HostName)
}

function Test-ZedLoopbackUrl {
    param([string]$Url)
    $h = Get-ZedUrlHost $Url
    if (-not $h) { return $false }
    return (Test-ZedLoopbackHost $h)
}

function Get-ZedCompletionsUrl {
    param([string]$Base)
    $query = ''
    $pathBase = $Base
    if ($pathBase -match '#') { $pathBase = ($pathBase -split '#', 2)[0] }
    if ($pathBase -match '\?') {
        $parts = $pathBase -split '\?', 2
        $query = $parts[1]
        $pathBase = $parts[0]
    }
    if ($pathBase -match '/v1$') {
        $completions = ($pathBase -replace '/$', '') + '/completions'
    } else {
        $completions = $pathBase + '/completions'
    }
    if ($query) { $completions = $completions + '?' + $query }
    return $completions
}

function Test-ZedModelName {
    param([string]$Value)
    if ($Value -match '["\\]') { Stop-Die "invalid characters in llm-model: quotes or backslashes not allowed" }
    if ($Value -match '[^A-Za-z0-9._-]') { Stop-Die "invalid characters in llm-model" }
}

function Test-ZedProviderName {
    param([string]$Value)
    if ($Value -match '["\\]') { Stop-Die "invalid characters in llm-provider-name: quotes or backslashes not allowed" }
    if ($Value -match '[^A-Za-z0-9_-]') { Stop-Die "invalid characters in llm-provider-name" }
}

function Test-LlmUrls {
    if ($script:DisableAi) { return }
    if (-not $script:LlmModel) { Stop-Die "-LlmModel is required unless -DisableAi is set" }
    Test-ZedModelName $script:LlmModel
    Test-ZedProviderName $script:LlmProviderName
    Test-UrlValid $script:LlmApiUrl 'llm-api-url'
    if (-not $script:CompletionsUrl) { $script:CompletionsUrl = Get-ZedCompletionsUrl $script:LlmApiUrl }
    Test-UrlValid $script:CompletionsUrl 'llm-completions-url'
    if (-not $script:AllowNonlocalLlm) {
        if (-not (Test-ZedLoopbackUrl $script:LlmApiUrl)) {
            Stop-Die "LLM API URL must be loopback (127.0.0.1/localhost/::1). Use -AllowNonlocalLlm to override."
        }
        if (-not (Test-ZedLoopbackUrl $script:CompletionsUrl)) {
            Stop-Die "LLM completions URL must be loopback. Use -AllowNonlocalLlm to override."
        }
    } else {
        Write-Warn "Non-local LLM URL allowed. Proprietary code may leave your machine via the LLM server."
    }
}

# --- platform checks (replace glibc / Vulkan / inotify) ---

function Test-WindowsPlatform {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $build = 0
        [void][int]::TryParse(($os.BuildNumber), [ref]$build)
        if ($build -gt 0 -and $build -lt 22000) {
            Write-Warn "Windows build $build detected; Zed targets Windows 11+ (build >= 22000)."
        } else {
            Write-Log "Windows build: $build"
        }
    } catch {
        Write-Warn "Could not determine Windows version"
    }

    # Best-effort DirectX 11 capability check (warn-only, like check_vulkan).
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        if ($gpus.Count -eq 0) {
            Write-Warn "No display adapter detected. Zed requires a DirectX 11 capable GPU."
        }
    } catch {
        Write-Warn "Could not query display adapters; ensure a DirectX 11 capable GPU is present (run dxdiag)."
    }

    if (-not (Test-Have 'winget')) {
        Write-Warn "winget (App Installer) not found. Install 'App Installer' from the Microsoft Store, or use ZED_BUNDLE_PATH."
    }
}

# --- install / locate Zed ---

function Test-ZedPathOnUserPath {
    $path = if ($env:Path) { $env:Path } else { '' }
    $parts = $path -split ';'
    if ($parts -notcontains $script:BinDir) {
        Write-Warn "$($script:BinDir) is not on PATH"
        Write-Warn "Add it so 'zed-secure' is available, or use the Start Menu shortcut."
    }
}

function Resolve-ZedAppPath {
    param([string]$ChannelName)
    $dir = Get-ZedChannelDirName $ChannelName
    $candidates = New-Object System.Collections.ArrayList

    $cmd = Get-Command 'zed.exe' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { [void]$candidates.Add($cmd.Source) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\$dir\Zed.exe")) }
    if ($env:ProgramFiles) { [void]$candidates.Add((Join-Path $env:ProgramFiles "$dir\Zed.exe")) }

    foreach ($root in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        try {
            if (Test-Path $root) {
                foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                    $name = $k.GetValue('DisplayName')
                    if ($name -and $name -like 'Zed*') {
                        $loc = $k.GetValue('InstallLocation')
                        if ($loc) { [void]$candidates.Add((Join-Path $loc 'Zed.exe')) }
                    }
                }
            }
        } catch { }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Install-ZedFromBundle {
    param([string]$Bundle)
    if (-not $DryRun -and -not (Test-Path -LiteralPath $Bundle)) {
        Stop-Die "ZED_BUNDLE_PATH not found: $Bundle"
    }
    $dir = Get-ZedChannelDirName $script:Channel
    $localApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
    $dest = Join-Path $localApp "Programs\$dir"
    Write-Log "Installing Zed from local bundle: $Bundle"
    Invoke-Step "Expand-Archive -Path $Bundle -DestinationPath $dest" {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
        Expand-Archive -LiteralPath $Bundle -DestinationPath $dest -Force
    }
}

function Install-ZedFromWinget {
    $wingetArgs = @('install', '-e', '--id', 'ZedIndustries.Zed', '--silent',
        '--accept-package-agreements', '--accept-source-agreements')
    if ($script:ZedVersion -ne 'latest') { $wingetArgs += @('--version', $script:ZedVersion) }
    Invoke-Step "winget $($wingetArgs -join ' ')" {
        & winget @wingetArgs
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            # -1978335189 = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE (already installed/current)
            throw "winget exited with code $LASTEXITCODE"
        }
    }
}

function Install-Zed {
    Write-Log "Installing Zed (channel=$($script:Channel) version=$($script:ZedVersion))"

    $existing = Resolve-ZedAppPath $script:Channel
    if (-not $DryRun -and $existing) {
        Write-Log "Zed already installed at $existing; skipping download"
        return
    }

    $bundle = $env:ZED_BUNDLE_PATH
    if ($script:Offline -and -not $bundle) {
        Stop-Die "-Offline requires ZED_BUNDLE_PATH when Zed is not already installed"
    }

    if ($bundle) {
        Install-ZedFromBundle $bundle
        return
    }
    if ($script:Offline) {
        Stop-Die "-Offline requires ZED_BUNDLE_PATH when Zed is not already installed"
    }
    if ($script:Channel -eq 'nightly' -or $script:Channel -eq 'dev') {
        Stop-Die "channel '$($script:Channel)' is unofficial on Windows; provide ZED_BUNDLE_PATH (.zip) to install it"
    }
    if ($script:Channel -eq 'preview') {
        Write-Warn "winget installs the stable channel; for 'preview' provide ZED_BUNDLE_PATH or install the preview build manually (https://zed.dev/releases/preview)."
    }
    Install-ZedFromWinget
}

# --- settings ---

function Test-ZedRunning {
    $procs = @(Get-Process -Name 'Zed', 'zed' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        Write-Warn "Zed is running; close it before install to avoid a settings.json race with the UI"
    }
}

function Write-ZedTemplateFile {
    if ($DryRun) {
        Write-Log "Would write $($script:SettingsTemplate)"
        return
    }
    if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    }
    $obj = New-ZedSettingsObject -DisableAi $script:DisableAi -DoNotHideEnvFiles $script:DoNotHideEnvFiles `
        -DisableLocalEditPredictions $script:DisableLocalEditPredictions -LlmProviderName $script:LlmProviderName `
        -LlmApiUrl $script:LlmApiUrl -LlmModel $script:LlmModel -LlmCompletionsUrl $script:CompletionsUrl
    $json = ConvertTo-ZedJson $obj
    Write-Utf8NoBom -Path $script:SettingsTemplate -Text $json
    Sync-ZedTemplateShare
}

function Sync-ZedTemplateShare {
    if (-not (Test-Path -LiteralPath $script:SettingsTemplate)) { return }
    if ($DryRun) {
        Write-Log "Would copy $($script:SettingsTemplate) -> $($script:SettingsTemplateShare)"
        return
    }
    if (-not (Test-Path -LiteralPath $script:ShareDir)) {
        New-Item -ItemType Directory -Force -Path $script:ShareDir | Out-Null
    }
    Copy-Item -LiteralPath $script:SettingsTemplate -Destination $script:SettingsTemplateShare -Force
}

function Backup-ZedSettings {
    if (Test-Path -LiteralPath $script:Settings) {
        $ts = Get-Date -Format 'yyyyMMddHHmmss'
        $backup = "$($script:Settings).bak.$ts"
        Invoke-Step "Copy-Item $($script:Settings) -> $backup" {
            Copy-Item -LiteralPath $script:Settings -Destination $backup -Force
        }
        Write-Log "Backed up existing settings to $backup"
    }
}

function Write-ZedSettings {
    Test-ZedRunning
    if (-not $DryRun -and -not (Test-Path -LiteralPath $script:ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    }
    Write-ZedTemplateFile

    if (-not (Test-Path -LiteralPath $script:Settings)) {
        if ($DryRun) {
            Write-Log "Would write $($script:Settings) from template"
        } else {
            Copy-Item -LiteralPath $script:SettingsTemplate -Destination $script:Settings -Force
        }
    } else {
        Backup-ZedSettings
        $refresh = ($script:Merge -or $script:Refresh)
        if ($DryRun) {
            if ($refresh) { Write-Log "Would refresh security + language_models in $($script:Settings)" }
            else { Write-Log "Would apply security-only overlay to $($script:Settings)" }
            [void](Invoke-EnforceZedSettings -Settings $script:Settings -Template $script:SettingsTemplate `
                -Share $script:SettingsTemplateShare -DryRun -RefreshLlm:$refresh)
        } else {
            $rc = Invoke-EnforceZedSettings -Settings $script:Settings -Template $script:SettingsTemplate `
                -Share $script:SettingsTemplateShare -RefreshLlm:$refresh
            if ($rc -eq 1) { Stop-Die "Failed to apply settings overlay (close Zed and retry)" }
            if ($rc -eq 2) { Write-Warn "Partial privacy fix (regex only). Close Zed and run -RepairSettings" }
        }
    }

    if (-not $DryRun -and (Test-Path -LiteralPath $script:Settings)) {
        if (Test-JsonParseable $script:Settings) { Write-Log "settings.json validated" }
        else { Write-Warn "settings.json failed JSON validation (Zed JSONC? the launcher will try the regex fallback)" }
        if (Test-ZedSecuritySettings $script:Settings) {
            Write-Log "Privacy settings verified (telemetry off, auto_update off)"
        } else {
            Write-Warn "Privacy verification failed immediately after write (close Zed and run -RepairSettings)"
        }
    }
}

function Test-ZedTemplateAvailable {
    if (Test-Path -LiteralPath $script:SettingsTemplate) { return $true }
    if (Test-Path -LiteralPath $script:SettingsTemplateShare) { return $true }
    return $false
}

function Invoke-RepairSettings {
    Test-ZedRunning
    Install-EnforceHelper
    if (-not $DryRun -and -not (Test-Path -LiteralPath $script:ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    }

    if ($script:Regen) {
        Write-Warn "Regenerating template from current parameters (-RegenerateTemplate)"
        Write-ZedTemplateFile
    } elseif (-not (Test-ZedTemplateAvailable)) {
        if (-not (Test-Path -LiteralPath $script:Settings)) {
            Stop-Die "settings.json missing; run a full install: Install-ZedNoAi.ps1 or Install-ZedLocalLlm.ps1 MODEL"
        }
        Write-Log "Template missing; inferring install mode from settings.json"
        $mode = Get-InferredZedInstallMode $script:Settings
        if (-not $mode) {
            Stop-Die "Cannot infer install mode from settings.json. Run Install-ZedNoAi.ps1 or Install-ZedLocalLlm.ps1 MODEL"
        }
        $script:DisableAi = [bool]$mode.DisableAi
        if (-not $script:DisableAi) {
            if ((Test-HasProp $mode 'Provider') -and $mode.Provider) { $script:LlmProviderName = $mode.Provider }
            if ((Test-HasProp $mode 'ApiUrl') -and $mode.ApiUrl) { $script:LlmApiUrl = $mode.ApiUrl }
            if ((Test-HasProp $mode 'Model') -and $mode.Model) { $script:LlmModel = $mode.Model }
            if (-not $script:CompletionsUrl) { $script:CompletionsUrl = Get-ZedCompletionsUrl $script:LlmApiUrl }
        }
        Write-ZedTemplateFile
    }

    if ($DryRun) {
        Write-Log "Would repair privacy settings in $($script:Settings)"
        return
    }
    $rc = Invoke-EnforceZedSettings -Settings $script:Settings -Template $script:SettingsTemplate `
        -Share $script:SettingsTemplateShare
    if ($rc -eq 1) { Stop-Die "Failed to repair settings" }
    if ($rc -eq 2) { Stop-Die "Partial repair (regex only). Close Zed and retry -RepairSettings" }
    if (-not (Test-ZedSecuritySettings $script:Settings)) { Stop-Die "Repair verification failed" }
    Write-Log "Privacy settings repaired"
}

# --- enforce helper + launcher ---

function Install-EnforceHelper {
    if ($DryRun) {
        Write-Log "Would install $($script:EnforceHelper)"
        Write-Log "Would sync $($script:SettingsTemplateShare)"
        return
    }
    if (-not (Test-Path -LiteralPath $script:ShareDir)) {
        New-Item -ItemType Directory -Force -Path $script:ShareDir | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ZedSecuritySettings.psm1') -Destination $script:EnforceModuleDest -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Enforce-ZedSettings.ps1') -Destination $script:EnforceHelper -Force
    if (Test-Path -LiteralPath $script:SettingsTemplate) {
        Sync-ZedTemplateShare
    } elseif ((Test-Path -LiteralPath $script:SettingsTemplateShare) -and -not (Test-Path -LiteralPath $script:SettingsTemplate)) {
        Copy-Item -LiteralPath $script:SettingsTemplateShare -Destination $script:SettingsTemplate -Force
        Write-Log "Restored $($script:SettingsTemplate) from share backup"
    }
}

function Write-ZedSecureLauncher {
    if ($DryRun) {
        Write-Log "Would write $($script:LauncherPs1) (Zed: $($script:ZedExe))"
        Write-Log "Would write $($script:LauncherVbs) and $($script:ZedSecureCmd)"
        return
    }
    if (-not (Test-Path -LiteralPath $script:ShareDir)) {
        New-Item -ItemType Directory -Force -Path $script:ShareDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:BinDir)) {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    }

    $zedEsc = $script:ZedExe -replace "'", "''"
    $shareEsc = $script:ShareDir -replace "'", "''"
    $keyList = ($script:CloudKeyVars | ForEach-Object { "'$_'" }) -join ', '

    $ps1 = @"
#Requires -Version 5.1
# zed-secure launcher (generated by Install-ZedSecure.ps1). Do not edit by hand.
# Clears cloud API key environment variables, re-applies the privacy overlay, then
# launches Zed. The network sandbox is a persistent Windows Firewall rule applied at
# install time and governs Zed.exe regardless of how it is launched.
`$ErrorActionPreference = 'SilentlyContinue'
`$ZedExe = '$zedEsc'
`$Share = '$shareEsc'
`$Settings = Join-Path `$env:APPDATA 'Zed\settings.json'
`$Template = Join-Path `$env:APPDATA 'Zed\settings.zed-secure-template.json'
`$EnforceHelper = Join-Path `$Share 'Enforce-ZedSettings.ps1'
foreach (`$v in @($keyList)) { Remove-Item "Env:`$v" -ErrorAction SilentlyContinue }
if ((`$env:ZED_SECURE_ENFORCE_SETTINGS -ne '0') -and (Test-Path -LiteralPath `$EnforceHelper)) {
    `$tpl = `$Template
    `$shareTpl = Join-Path `$Share 'settings-template.json'
    if (-not (Test-Path -LiteralPath `$tpl) -and (Test-Path -LiteralPath `$shareTpl)) { `$tpl = `$shareTpl }
    & powershell -NoProfile -ExecutionPolicy Bypass -File `$EnforceHelper `$Settings `$tpl
    `$rc = `$LASTEXITCODE
    if (`$rc -ne 0) {
        if (`$rc -eq 2) {
            [Console]::Error.WriteLine('WARNING: zed-secure: partial privacy fix (regex only). Close Zed and run: Install-ZedSecure.ps1 -RepairSettings')
        } else {
            [Console]::Error.WriteLine('WARNING: zed-secure: privacy overlay failed. Run: Install-ZedSecure.ps1 -RepairSettings')
        }
        if (`$env:ZED_SECURE_ENFORCE_STRICT -eq '1') { exit 1 }
    }
}
& `$ZedExe `@args
exit `$LASTEXITCODE
"@
    Write-Utf8NoBom -Path $script:LauncherPs1 -Text $ps1

    $launcherEsc = $script:LauncherPs1.Replace('"', '""')
    $vbs = @"
' zed-secure no-flash launcher (generated). Runs the PowerShell launcher hidden.
Set sh = CreateObject("WScript.Shell")
extra = ""
For Each a In WScript.Arguments
  extra = extra & " " & """" & a & """"
Next
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$launcherEsc""" & extra, 0, False
"@
    Write-Utf8NoBom -Path $script:LauncherVbs -Text $vbs

    $cmd = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$($script:LauncherPs1)" %*
"@
    Write-Utf8NoBom -Path $script:ZedSecureCmd -Text $cmd

    Write-Log "Created launcher: $($script:LauncherPs1)"
    Test-ZedPathOnUserPath
}

# --- GUI / CLI integration ---

function Get-ZedShortcutPaths {
    $paths = New-Object System.Collections.ArrayList
    $cands = @()
    if ($env:APPDATA) { $cands += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Zed.lnk') }
    if ($env:ProgramData) { $cands += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Zed.lnk') }
    if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE 'Desktop\Zed.lnk') }
    if ($env:PUBLIC) { $cands += (Join-Path $env:PUBLIC 'Desktop\Zed.lnk') }
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { [void]$paths.Add($c) } }
    return $paths
}

function Repair-Shortcuts {
    $shortcuts = Get-ZedShortcutPaths
    if ($shortcuts.Count -eq 0) {
        if ($DryRun) { Write-Log "Would patch Start Menu / Desktop Zed shortcut (none found in dry-run scan)" }
        else { Write-Warn "No Zed shortcut found; skipping GUI launcher patch" }
        return
    }
    foreach ($lnk in $shortcuts) {
        if ($DryRun) {
            Write-Log "Would patch shortcut: $lnk -> $($script:LauncherVbs)"
            continue
        }
        $ts = Get-Date -Format 'yyyyMMddHHmmss'
        Copy-Item -LiteralPath $lnk -Destination "$lnk.bak.$ts" -Force
        try {
            $wsh = New-Object -ComObject WScript.Shell
            $sc = $wsh.CreateShortcut($lnk)
            $sc.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
            $sc.Arguments = '"' + $script:LauncherVbs + '"'
            $sc.Save()
            Write-Log "Patched shortcut: $lnk (backup: $lnk.bak.$ts)"
        } catch {
            Write-Warn "Failed to patch shortcut $lnk : $_"
        }
    }
}

function Set-ReplaceZedCli {
    if (-not $script:ReplaceCli) { return }
    if ($DryRun) {
        Write-Log "Would replace the 'zed' command on PATH with a shim to $($script:LauncherPs1)"
        Write-Log "Would backup existing 'zed' command if present"
        return
    }
    if (-not (Test-Path -LiteralPath $script:BinDir)) {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    }
    if (Test-Path -LiteralPath $script:ZedCliShim) {
        $ts = Get-Date -Format 'yyyyMMddHHmmss'
        Copy-Item -LiteralPath $script:ZedCliShim -Destination "$($script:ZedCliShim).bak.zed-secure.$ts" -Force
        Write-Log "Backed up existing $($script:ZedCliShim)"
    }
    $shim = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$($script:LauncherPs1)" %*
"@
    Write-Utf8NoBom -Path $script:ZedCliShim -Text $shim
    Write-Log "Replaced 'zed' on PATH ($($script:ZedCliShim)) -> launcher"
}

function Restore-ZedCli {
    $latest = Get-ChildItem -LiteralPath $script:BinDir -Filter 'zed.cmd.bak.zed-secure.*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Invoke-Step "Restore $($script:ZedCliShim) from backup" {
            Copy-Item -LiteralPath $latest.FullName -Destination $script:ZedCliShim -Force
            Remove-Item -LiteralPath $latest.FullName -Force
        }
    } elseif (Test-Path -LiteralPath $script:ZedCliShim) {
        Invoke-Step "Remove zed-secure shim at $($script:ZedCliShim)" {
            Remove-Item -LiteralPath $script:ZedCliShim -Force
        }
    }
}

# --- network sandbox (per-app firewall) + hosts + machine-wide strict ---
# Privileged operations are batched and run once via Invoke-ZedFirewallStep.ps1 (UAC).

function Test-SandboxAvailable {
    if (-not $script:EnableSandbox) { return }
    if ($DryRun) {
        Write-Log "Would verify Windows Firewall (New-NetFirewallRule) availability"
        return
    }
    $ok = [bool](Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)
    if ($ok) {
        try {
            $svc = Get-Service -Name 'MpsSvc' -ErrorAction Stop
            if ($svc.Status -ne 'Running') { $ok = $false }
        } catch { $ok = $false }
    }
    if (-not $ok) {
        if ($script:AllowNoSandbox) {
            Write-Warn "Windows Firewall sandbox unavailable; continuing without network sandbox"
            $script:EnableSandbox = $false
            return
        }
        Stop-Die "Windows Firewall (New-NetFirewallRule / MpsSvc) unavailable. Pass -AllowNoSandbox to continue."
    }
    Write-Log "Network sandbox available via Windows Defender Firewall"
}

function Set-EgressFirewall {
    if (-not $script:EnableSandbox) { return }
    if ($DryRun) {
        Write-Log "Would create per-app Windows Firewall rule blocking outbound for $($script:ZedExe) (loopback allowed; requires admin)"
        return
    }
    $script:PrivilegedArgs += @('-AddEgressRule')
}

function Add-HostsBlocklist {
    if (-not $script:EnableBlocklist) { return }
    if ($DryRun) {
        Write-Log "Would append hosts blocklist to $($script:HostsPath) (requires admin)"
        foreach ($d in $script:BlocklistDomains) { [Console]::Out.WriteLine("[dry-run] 0.0.0.0 $d") }
        return
    }
    $script:PrivilegedArgs += @('-AddHostsBlocklist')
}

function Write-HostsOnlyNote {
    if (-not $script:EnableBlocklist) { return }
    if ($DryRun) {
        Write-Log "Endpoint blocklist is hosts-only on Windows; use -EnableNetworkSandbox for per-app process isolation"
        return
    }
    Write-Log "Endpoint blocklist: hosts-only"
}

function Remove-HostsBlocklist {
    if ($DryRun) {
        Write-Log "Would remove hosts blocklist markers from $($script:HostsPath)"
        return
    }
    $script:PrivilegedArgs += @('-RemoveHostsBlocklist')
}

function Invoke-MachineWideStrictFirewall {
    if (-not $script:MachineWide) { return }
    Write-Warn "DANGEROUS: machine-wide strict firewall enabled"
    Write-Warn "This blocks ALL outbound traffic for the whole machine except loopback, not just Zed."
    Write-Warn "Browsers, git, package managers, SSH and other tools may lose network access."
    Write-Warn "This is NOT the same as the per-app sandbox or the hosts blocklist."
    Write-Warn "To remove: Install-ZedSecure.ps1 -Uninstall"
    if ($DryRun) {
        Write-Log "Would create firewall rules blocking outbound for this machine except loopback"
        return
    }
    if (-not $script:Yes) {
        Write-Warn "Applying machine-wide firewall in 5 seconds... (use -Yes to skip this pause)"
        for ($i = 5; $i -gt 0; $i--) {
            [Console]::Error.WriteLine("  $i...")
            Start-Sleep -Seconds 1
        }
    }
    $script:PrivilegedArgs += @('-StrictFirewall')
}

function Invoke-PrivilegedStep {
    if ($DryRun) { return }
    if (-not $script:PrivilegedArgs -or $script:PrivilegedArgs.Count -eq 0) { return }
    $sub = Join-Path $PSScriptRoot 'Invoke-ZedFirewallStep.ps1'
    $common = @('-HostsPath', "`"$($script:HostsPath)`"", '-ZedExe', "`"$($script:ZedExe)`"",
        '-RuleGroup', $script:FirewallGroup, '-StrictGroup', $script:FirewallStrictGroup,
        '-Domains', ($script:BlocklistDomains -join ','))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$sub`"") + $script:PrivilegedArgs + $common
    Write-Log "Elevating to apply firewall/hosts changes (UAC prompt)..."
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Warn "Privileged firewall/hosts step exited with code $($p.ExitCode)" }
    } catch {
        Write-Warn "Could not elevate for firewall/hosts changes: $_"
    }
    $script:PrivilegedArgs = @()
}

# --- summary ---

function Write-Summary {
    $aiMode = if ($script:DisableAi) { 'disabled' } else { 'local OpenAI-compatible' }
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('=== Zed Secure Install Summary ===')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("Config:     $($script:Settings)")
    [Console]::Out.WriteLine("Launcher:   $($script:LauncherVbs)")
    [Console]::Out.WriteLine("Zed binary: $($script:ZedExe)")
    [Console]::Out.WriteLine("Channel:    $($script:Channel)")
    [Console]::Out.WriteLine("AI mode:    $aiMode")
    if (-not $script:DisableAi) {
        [Console]::Out.WriteLine("LLM API:    $($script:LlmApiUrl)")
        [Console]::Out.WriteLine("LLM completions: $($script:CompletionsUrl)")
        [Console]::Out.WriteLine("LLM model:  $($script:LlmModel)")
    }
    $sandbox = if ($script:EnableSandbox) { 'enabled (per-app Windows Firewall; loopback allowed)' } else { 'disabled' }
    $blocklist = if ($script:EnableBlocklist) { 'enabled (hosts only; no machine-wide rules)' } else { 'disabled' }
    [Console]::Out.WriteLine("Sandbox:    $sandbox")
    [Console]::Out.WriteLine("Blocklist:  $blocklist")
    if ($script:ReplaceCli) {
        [Console]::Out.WriteLine("CLI alias:  $($script:ZedCliShim) -> $($script:LauncherPs1)")
    }
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('Launch Zed securely:')
    [Console]::Out.WriteLine('  zed-secure .')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('IMPORTANT limitations:')
    [Console]::Out.WriteLine('  - Do NOT sign in to a Zed account or add cloud API keys (Credential Manager not cleared)')
    [Console]::Out.WriteLine('  - The per-app firewall blocks Zed.exe only; child processes (LSPs, node, git) are not covered')
    [Console]::Out.WriteLine('  - Use -MachineWideStrictFirewall for full egress lockdown (blocks the whole machine)')
    [Console]::Out.WriteLine('  - Endpoint blocklist is hosts-only and does NOT replace the sandbox')
    [Console]::Out.WriteLine('  - Zed UI may re-enable telemetry; the launcher re-applies the privacy overlay each launch')
    [Console]::Out.WriteLine('  - Run: Install-ZedSecure.ps1 -RepairSettings (Zed closed) to fix settings.json')
    [Console]::Out.WriteLine('')
}

# --- uninstall ---

function Invoke-Uninstall {
    Write-Log "Uninstalling zed-secure components"
    foreach ($f in @($script:LauncherPs1, $script:LauncherVbs, $script:ZedSecureCmd, $script:EnforceHelper, $script:EnforceModuleDest)) {
        if (Test-Path -LiteralPath $f) { Invoke-Step "Remove $f" { Remove-Item -LiteralPath $f -Force } }
    }
    Restore-ZedCli
    Restore-Shortcuts
    Remove-HostsBlocklist
    $script:PrivilegedArgs += @('-RemoveEgressRule', '-RemoveStrictFirewall')
    Invoke-PrivilegedStep
    Write-Log "Uninstall complete. Zed itself was NOT removed."
    Write-Log "To remove Zed: winget uninstall -e --id ZedIndustries.Zed (or via Settings > Apps)"
}

function Restore-Shortcuts {
    foreach ($lnk in @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Zed.lnk'),
            (Join-Path $env:USERPROFILE 'Desktop\Zed.lnk'))) {
        $dir = Split-Path -Parent $lnk
        $name = Split-Path -Leaf $lnk
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $latest = Get-ChildItem -LiteralPath $dir -Filter "$name.bak.*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            Invoke-Step "Restore shortcut $lnk" { Copy-Item -LiteralPath $latest.FullName -Destination $lnk -Force }
            Write-Log "Restored shortcut from $($latest.Name)"
        }
    }
}

# --- main ---

function Invoke-Main {
    if ($Help) { Show-Usage; exit 0 }
    Initialize-ZedState
    Test-FirewallAcceptFlags
    Set-LocalAiSandboxDefault
    Set-InstallActionRequested

    if ($script:Uninstall) {
        Invoke-Uninstall
        exit 0
    }

    if ($script:DisableBlocklist) {
        Remove-HostsBlocklist
        Invoke-PrivilegedStep
        if (-not $script:ActionRequested) {
            Write-Log "Endpoint blocklist removed"
            exit 0
        }
    }

    if ($script:Repair) {
        Invoke-RepairSettings
        exit 0
    }

    Test-ZedChannel
    Test-LlmUrls
    Test-WindowsPlatform
    Test-SandboxAvailable

    Install-Zed
    if ($DryRun) {
        # Mirror the Linux installer, which shows the channel-specific app path regardless of
        # whether Zed is already installed.
        $script:ZedExe = Get-SyntheticZedExe $script:Channel
    } else {
        $resolved = Resolve-ZedAppPath $script:Channel
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) {
            Stop-Die "Zed binary not found after install (channel=$($script:Channel)). Check the install output."
        }
        $script:ZedExe = $resolved
    }

    Write-ZedSettings
    Install-EnforceHelper
    Write-ZedSecureLauncher
    Set-ReplaceZedCli
    Repair-Shortcuts

    Set-EgressFirewall
    Add-HostsBlocklist
    Write-HostsOnlyNote
    Invoke-MachineWideStrictFirewall
    Invoke-PrivilegedStep

    Write-Summary
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
    exit 0
}
