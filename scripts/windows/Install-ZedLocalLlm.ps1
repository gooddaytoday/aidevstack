#Requires -Version 5.1
# Install-ZedLocalLlm.ps1 - Preset: local LLM with deps check, blocklist, network sandbox.
# Wraps Install-ZedSecure.ps1 with the recommended flags. MODEL must be the first argument.

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage: Install-ZedLocalLlm.ps1 MODEL [OPTIONS]

Install Zed Secure for a local OpenAI-compatible LLM (recommended setup).
MODEL must be the first argument (cannot start with "-").
OPTIONS are forwarded to Install-ZedSecure.ps1 (e.g. -DryRun, -MergeConfig).

The preset always passes: -InstallDeps, -EnableEndpointBlocklist, a loopback LLM URL,
and the network sandbox (enabled by the main installer when -LlmModel is set).
Forwarded flags can override preset behavior (e.g. -NoNetworkSandbox).

Examples:
  .\Install-ZedLocalLlm.ps1 your-model-name
  .\Install-ZedLocalLlm.ps1 qwen2.5-coder -DryRun
'@ | ForEach-Object { [Console]::Error.WriteLine($_) }
}

if ($args.Count -ge 1 -and ($args[0] -eq '-h' -or $args[0] -eq '-Help' -or $args[0] -eq '--help' -or $args[0] -eq '/?')) {
    Show-Usage
    exit 0
}

if ($args.Count -lt 1) {
    Show-Usage
    exit 1
}

$model = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }

if ($model -like '-*') {
    [Console]::Error.WriteLine('ERROR: MODEL must be the first argument and cannot start with "-".')
    if ($model -eq '-DryRun' -or $model -eq '--dry-run') {
        [Console]::Error.WriteLine('Hint: put the model name first: .\Install-ZedLocalLlm.ps1 your-model-name -DryRun')
    } else {
        [Console]::Error.WriteLine('Hint: .\Install-ZedLocalLlm.ps1 your-model-name [OPTIONS]')
    }
    Show-Usage
    exit 1
}

$installer = Join-Path $PSScriptRoot 'Install-ZedSecure.ps1'
if (-not (Test-Path -LiteralPath $installer)) {
    [Console]::Error.WriteLine("ERROR: missing $installer")
    exit 1
}

$llmApiUrl = if ($env:ZED_LLM_API_URL) { $env:ZED_LLM_API_URL } else { 'http://127.0.0.1:8080/v1' }
& $installer -InstallDeps -LlmModel $model -LlmApiUrl $llmApiUrl -EnableEndpointBlocklist @rest
exit $LASTEXITCODE
