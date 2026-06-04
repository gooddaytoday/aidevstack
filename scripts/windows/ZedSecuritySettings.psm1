#Requires -Version 5.1
# ZedSecuritySettings.psm1 - Apply/verify Zed privacy settings overlay (Windows).
# Port of scripts/zed-security-settings.sh. Windows PowerShell 5.1 compatible.
# Imported by Install-ZedSecure.ps1 and by Enforce-ZedSettings.ps1 (launch-time enforce).
#
# Design notes (PowerShell 5.1 footguns this module works around):
#   * ConvertTo-Json in 5.1 unwraps single-element arrays (available_models[0] would
#     break) and writes a UTF-8 BOM. We therefore use a custom serializer
#     (ConvertTo-ZedJson) + BOM-less writer (Write-Utf8NoBom). Reading uses the
#     reliable ConvertFrom-Json AFTER our own JSONC normalizer.
#   * 5.1 ConvertFrom-Json has no comment/trailing-comma tolerance, so we strip
#     comments (string-literal aware) and trailing commas before parsing.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- logging (warnings go to stderr, like warn_msg in the sh module) ---

function Write-ZedWarn {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("WARNING: $Message")
}

# --- object helpers ---

function Test-IsPSObject {
    param($Value)
    return ($Value -is [System.Management.Automation.PSCustomObject])
}

# True if $Object is a PSCustomObject that has a property named $Name (value may be null).
function Test-HasProp {
    param($Object, [string]$Name)
    if (-not (Test-IsPSObject $Object)) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

# --- JSON serialization (single-element-array safe, BOM-less, stable key order) ---

function ConvertTo-ZedJsonString {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ([string]$ch) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`b" { [void]$sb.Append('\b') }
            "`f" { [void]$sb.Append('\f') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                $code = [int][char]$ch
                if ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-ZedJson {
    param($Value, [int]$Depth = 0)
    $nl = "`n"
    $pad = '  ' * $Depth
    $pad1 = '  ' * ($Depth + 1)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-ZedJsonString $Value) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or `
        $Value -is [sbyte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return ([string]$Value)
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $parts = @()
        foreach ($k in $keys) {
            $parts += ($pad1 + (ConvertTo-ZedJsonString ([string]$k)) + ': ' + (ConvertTo-ZedJson $Value[$k] ($Depth + 1)))
        }
        return '{' + $nl + ($parts -join (',' + $nl)) + $nl + $pad + '}'
    }
    if (Test-IsPSObject $Value) {
        $props = @($Value.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $parts = @()
        foreach ($p in $props) {
            $parts += ($pad1 + (ConvertTo-ZedJsonString $p.Name) + ': ' + (ConvertTo-ZedJson $p.Value ($Depth + 1)))
        }
        return '{' + $nl + ($parts -join (',' + $nl)) + $nl + $pad + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $arr = @($Value)
        if ($arr.Count -eq 0) { return '[]' }
        $parts = @()
        foreach ($e in $arr) {
            $parts += ($pad1 + (ConvertTo-ZedJson $e ($Depth + 1)))
        }
        return '[' + $nl + ($parts -join (',' + $nl)) + $nl + $pad + ']'
    }
    return (ConvertTo-ZedJsonString ([string]$Value))
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path,
          [Parameter(Mandatory = $true)][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# --- JSONC normalization (strip // and /* */ comments + trailing commas) ---

# Removes comments OUTSIDE of string literals, then trailing commas before } or ].
# The string-literal alternation is critical: a naive strip would corrupt a URL like
# "http://127.0.0.1" inside an api_url value.
function Remove-JsonCommentsAndCommas {
    param([string]$Text)
    $re = [regex]'("(?:\\.|[^"\\])*")|/\*[\s\S]*?\*/|//[^\r\n]*'
    $evaluator = {
        param($m)
        if ($m.Groups[1].Success) { return $m.Groups[1].Value }
        return ''
    }
    $stripped = $re.Replace($Text, $evaluator)
    for ($i = 0; $i -lt 50; $i++) {
        $next = [regex]::Replace($stripped, ',(\s*[}\]])', '$1')
        if ($next -eq $stripped) { break }
        $stripped = $next
    }
    return $stripped
}

function ConvertFrom-JsoncText {
    param([string]$Text)
    try { return ($Text | ConvertFrom-Json -ErrorAction Stop) } catch { }
    $norm = Remove-JsonCommentsAndCommas $Text
    try { return ($norm | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function ConvertFrom-JsoncFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path)
    return (ConvertFrom-JsoncText $text)
}

function Test-JsonParseable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        [void]([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop)
        return $true
    } catch { return $false }
}

# --- deep merge + security overlay (mirror jq '$old * $new' then forced overwrites) ---

# Deep-merge two PSCustomObjects. Nested objects recurse; arrays and scalars are
# REPLACED wholesale by the overlay (matching jq '*' semantics).
function Merge-PSObjectDeep {
    param($Base, $Overlay)
    if (-not (Test-IsPSObject $Base) -or -not (Test-IsPSObject $Overlay)) { return $Overlay }
    $d = [ordered]@{}
    foreach ($p in $Base.PSObject.Properties) { $d[$p.Name] = $p.Value }
    foreach ($p in $Overlay.PSObject.Properties) {
        if ($d.Contains($p.Name) -and (Test-IsPSObject $d[$p.Name]) -and (Test-IsPSObject $p.Value)) {
            $d[$p.Name] = Merge-PSObjectDeep $d[$p.Name] $p.Value
        } else {
            $d[$p.Name] = $p.Value
        }
    }
    return [pscustomobject]$d
}

# Apply the security overlay: deep-merge then force-overwrite the security keys from
# the template. Preserves all other user keys. When -RefreshLlm, also overwrites
# language_models (mirrors full_overlay_merge); otherwise language_models is left to
# the deep-merge result (mirrors security_overlay_merge).
function Merge-ZedOverlay {
    param($Existing, $Template, [bool]$RefreshLlm = $false)
    $merged = Merge-PSObjectDeep $Existing $Template
    $d = [ordered]@{}
    foreach ($p in $merged.PSObject.Properties) { $d[$p.Name] = $p.Value }
    foreach ($k in @('auto_update', 'disable_ai', 'telemetry', 'title_bar', 'agent',
                     'session', 'collaboration_panel', 'file_scan_exclusions', 'edit_predictions')) {
        if (Test-HasProp $Template $k) { $d[$k] = $Template.$k }
    }
    if (Test-HasProp $Template 'show_edit_predictions') {
        $d['show_edit_predictions'] = $Template.show_edit_predictions
    }
    if ($RefreshLlm -and (Test-HasProp $Template 'language_models')) {
        $d['language_models'] = $Template.language_models
    }
    return [pscustomobject]$d
}

# --- regex privacy fallback (mirror privacy_sed_fallback): fix 4 keys in-place ---

function Repair-ZedPrivacyByRegex {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $t = [System.IO.File]::ReadAllText($Path)
        $t = [regex]::Replace($t, '"diagnostics"\s*:\s*true', '"diagnostics": false')
        $t = [regex]::Replace($t, '"metrics"\s*:\s*true', '"metrics": false')
        $t = [regex]::Replace($t, '"auto_update"\s*:\s*true', '"auto_update": false')
        $t = [regex]::Replace($t, '"trust_all_worktrees"\s*:\s*true', '"trust_all_worktrees": false')
        Write-Utf8NoBom -Path $Path -Text $t
        return $true
    } catch { return $false }
}

Set-Alias -Name Repair-ZedTelemetryByRegex -Value Repair-ZedPrivacyByRegex

# --- template generation (mirror generate_settings_content + *_json helpers) ---

function New-ZedSettingsObject {
    param(
        [bool]$DisableAi,
        [bool]$DoNotHideEnvFiles,
        [bool]$DisableLocalEditPredictions,
        [string]$LlmProviderName = 'LocalLLM',
        [string]$LlmApiUrl = 'http://127.0.0.1:8080/v1',
        [string]$LlmModel = '',
        [string]$LlmCompletionsUrl = ''
    )

    $fileScan = @('**/.git', '**/.svn', '**/.hg', '**/CVS', '**/.DS_Store', '**/Thumbs.db', '**/.class')
    if (-not $DoNotHideEnvFiles) { $fileScan += '**/.env*' }
    $fileScan += @('**/*.pem', '**/*.key', '**/secrets/**', '**/credentials/**')

    $settings = [ordered]@{
        auto_update = $false
        disable_ai  = $DisableAi
        telemetry   = [ordered]@{ diagnostics = $false; metrics = $false }
        session     = [ordered]@{ trust_all_worktrees = $false }
        title_bar   = [ordered]@{
            show_sign_in           = $false
            show_onboarding_banner = $false
            show_user_picture      = $false
            show_user_menu         = $false
        }
        collaboration_panel  = [ordered]@{ button = $false }
        file_scan_exclusions = @($fileScan)
    }

    if (-not $DisableAi) {
        $provider = [ordered]@{
            api_url          = $LlmApiUrl
            available_models = @(
                [ordered]@{
                    name         = $LlmModel
                    display_name = 'Local LLM'
                    max_tokens   = 32768
                    capabilities = [ordered]@{
                        tools               = $true
                        images              = $false
                        parallel_tool_calls = $false
                        prompt_cache_key    = $false
                    }
                }
            )
        }
        $openai = [ordered]@{}
        $openai[$LlmProviderName] = $provider
        $settings['language_models'] = [ordered]@{ openai_compatible = $openai }
    }

    $settings['agent'] = [ordered]@{
        tool_permissions = [ordered]@{
            default = 'confirm'
            tools   = [ordered]@{
                fetch      = [ordered]@{ default = 'deny' }
                search_web = [ordered]@{ default = 'deny' }
                terminal   = [ordered]@{
                    default     = 'confirm'
                    always_deny = @(
                        [ordered]@{ pattern = 'api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|cloud\.zed\.dev' }
                    )
                }
                edit_file  = [ordered]@{
                    default     = 'confirm'
                    always_deny = @(
                        [ordered]@{ pattern = '\.env' },
                        [ordered]@{ pattern = 'secrets?/' },
                        [ordered]@{ pattern = '\.(pem|key|crt|p12)$' }
                    )
                }
                write_file = [ordered]@{
                    default     = 'confirm'
                    always_deny = @(
                        [ordered]@{ pattern = '\.env' },
                        [ordered]@{ pattern = 'secrets?/' },
                        [ordered]@{ pattern = '\.(pem|key|crt|p12)$' }
                    )
                }
                delete_path = [ordered]@{ default = 'confirm' }
            }
        }
    }

    if (-not $DisableAi -and -not $DisableLocalEditPredictions) {
        $settings['edit_predictions'] = [ordered]@{
            provider               = 'open_ai_compatible_api'
            open_ai_compatible_api = [ordered]@{
                api_url           = $LlmCompletionsUrl
                model             = $LlmModel
                prompt_format     = 'infer'
                max_output_tokens = 512
            }
            disabled_globs         = @('**/.env*', '**/*.pem', '**/*.key', '**/secrets/**')
        }
    } else {
        $settings['show_edit_predictions'] = $false
        $settings['edit_predictions'] = [ordered]@{ provider = 'none' }
    }

    return $settings
}

# --- template resolution / verify / enforce ---

function Resolve-ZedSecurityTemplate {
    param([string]$Primary, [string]$Share)
    if ($Primary -and (Test-Path -LiteralPath $Primary)) { return $Primary }
    if ($Share -and (Test-Path -LiteralPath $Share)) { return $Share }
    return $null
}

# Returns $true if telemetry.metrics, telemetry.diagnostics and auto_update are all false.
function Test-ZedSecuritySettings {
    param([string]$Path)
    $obj = $null
    if (Test-JsonParseable $Path) {
        $obj = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    } else {
        $obj = ConvertFrom-JsoncFile $Path
    }

    if ($null -ne $obj) {
        $ok = $true
        if (-not (Test-HasProp $obj 'telemetry')) {
            Write-ZedWarn 'telemetry is missing'
            $ok = $false
        } else {
            if (-not (Test-HasProp $obj.telemetry 'metrics') -or $obj.telemetry.metrics -ne $false) {
                Write-ZedWarn 'telemetry.metrics is not false'
                $ok = $false
            }
            if (-not (Test-HasProp $obj.telemetry 'diagnostics') -or $obj.telemetry.diagnostics -ne $false) {
                Write-ZedWarn 'telemetry.diagnostics is not false'
                $ok = $false
            }
        }
        if (-not (Test-HasProp $obj 'auto_update') -or $obj.auto_update -ne $false) {
            Write-ZedWarn 'auto_update is not false'
            $ok = $false
        }
        return $ok
    }

    $text = ''
    try { $text = [System.IO.File]::ReadAllText($Path) } catch { return $false }
    $ok = $true
    if ($text -notmatch '"metrics"\s*:\s*false') {
        Write-ZedWarn 'telemetry.metrics is not false (JSONC; text check)'
        $ok = $false
    }
    if ($text -notmatch '"diagnostics"\s*:\s*false') {
        Write-ZedWarn 'telemetry.diagnostics is not false (JSONC; text check)'
        $ok = $false
    }
    return $ok
}

# Infer install mode from an existing settings.json (for template regeneration on repair).
# Returns [pscustomobject]@{ DisableAi; Provider; ApiUrl; Model } or $null.
function Get-InferredZedInstallMode {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $obj = $null
    if (Test-JsonParseable $Path) {
        $obj = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    } else {
        $obj = ConvertFrom-JsoncFile $Path
    }

    if ($null -eq $obj) {
        $text = ''
        try { $text = [System.IO.File]::ReadAllText($Path) } catch { return $null }
        if ($text -match '"disable_ai"\s*:\s*true') { return [pscustomobject]@{ DisableAi = $true } }
        if ($text -match 'openai_compatible') { return [pscustomobject]@{ DisableAi = $false } }
        return $null
    }

    if ((Test-HasProp $obj 'disable_ai') -and $obj.disable_ai -eq $true) {
        return [pscustomobject]@{ DisableAi = $true }
    }
    if ((Test-HasProp $obj 'language_models') -and (Test-HasProp $obj.language_models 'openai_compatible')) {
        $oc = $obj.language_models.openai_compatible
        $names = @($oc.PSObject.Properties.Name)
        if ($names.Count -gt 0) {
            $p = $names[0]
            $prov = $oc.$p
            $api = $null
            $model = $null
            if (Test-HasProp $prov 'api_url') { $api = $prov.api_url }
            if (Test-HasProp $prov 'available_models') {
                $am = @($prov.available_models)
                if ($am.Count -gt 0 -and (Test-HasProp $am[0] 'name')) { $model = $am[0].name }
            }
            return [pscustomobject]@{ DisableAi = $false; Provider = $p; ApiUrl = $api; Model = $model }
        }
        return [pscustomobject]@{ DisableAi = $false }
    }
    return $null
}

# Apply the privacy overlay. Returns 0 = full overlay, 2 = partial regex-only, 1 = failure.
function Invoke-EnforceZedSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Settings,
        [string]$Template = '',
        [string]$Share = '',
        [switch]$DryRun,
        [switch]$RefreshLlm
    )

    if (-not $Share) {
        if ($env:ZED_SECURE_TEMPLATE_SHARE) { $Share = $env:ZED_SECURE_TEMPLATE_SHARE }
        elseif ($env:LOCALAPPDATA) { $Share = Join-Path $env:LOCALAPPDATA 'zed-secure\settings-template.json' }
    }

    $tpl = Resolve-ZedSecurityTemplate -Primary $Template -Share $Share
    if (-not $tpl) {
        Write-ZedWarn "Security template missing (config and $Share)"
        if (-not (Test-Path -LiteralPath $Settings)) { return 1 }
        if ($DryRun) {
            [Console]::Out.WriteLine("[dry-run] would run privacy regex fallback on $Settings (no template)")
            return 0
        }
        if (Repair-ZedPrivacyByRegex $Settings) {
            Write-ZedWarn 'Partial fix (regex only). Re-run installer to regenerate template.'
            return 2
        }
        return 1
    }

    if (-not (Test-Path -LiteralPath $Settings)) {
        if ($DryRun) {
            [Console]::Out.WriteLine("[dry-run] would create $Settings from template")
            return 0
        }
        $dir = Split-Path -Parent $Settings
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Copy-Item -LiteralPath $tpl -Destination $Settings -Force
        return 0
    }

    $obj = $null
    if (Test-JsonParseable $Settings) {
        $obj = [System.IO.File]::ReadAllText($Settings) | ConvertFrom-Json -ErrorAction Stop
    } else {
        $obj = ConvertFrom-JsoncFile $Settings
    }

    if ($null -ne $obj) {
        if ($DryRun) {
            [Console]::Out.WriteLine("[dry-run] would apply security overlay to $Settings")
            return 0
        }
        $tplObj = ConvertFrom-JsoncFile $tpl
        if ($null -eq $tplObj) {
            Write-ZedWarn "Security template is not valid JSON: $tpl"
            return 1
        }
        $result = Merge-ZedOverlay -Existing $obj -Template $tplObj -RefreshLlm ([bool]$RefreshLlm)
        $json = ConvertTo-ZedJson $result
        $tmp = "$Settings.zedsecure.tmp"
        Write-Utf8NoBom -Path $tmp -Text $json
        Move-Item -LiteralPath $tmp -Destination $Settings -Force
        return 0
    }

    Write-ZedWarn 'settings.json is not valid JSON (Zed JSONC?). Trying privacy regex fallback.'
    if ($DryRun) {
        [Console]::Out.WriteLine("[dry-run] would run privacy regex fallback on $Settings")
        return 0
    }
    if (Repair-ZedPrivacyByRegex $Settings) {
        Write-ZedWarn 'Partial fix applied (regex). Close Zed and run: Install-ZedSecure.ps1 -RepairSettings'
        return 2
    }
    Write-ZedWarn 'Could not enforce settings. Close Zed and run: Install-ZedSecure.ps1 -RepairSettings'
    return 1
}

Export-ModuleMember -Function `
    Write-ZedWarn, Test-IsPSObject, Test-HasProp, `
    ConvertTo-ZedJsonString, ConvertTo-ZedJson, Write-Utf8NoBom, `
    Remove-JsonCommentsAndCommas, ConvertFrom-JsoncText, ConvertFrom-JsoncFile, Test-JsonParseable, `
    Merge-PSObjectDeep, Merge-ZedOverlay, Repair-ZedPrivacyByRegex, `
    New-ZedSettingsObject, Resolve-ZedSecurityTemplate, Test-ZedSecuritySettings, `
    Get-InferredZedInstallMode, Invoke-EnforceZedSettings `
    -Alias Repair-ZedTelemetryByRegex
