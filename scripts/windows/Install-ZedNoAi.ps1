#Requires -Version 5.1
# Install-ZedNoAi.ps1 - Preset: maximum privacy, no local LLM.
# Wraps Install-ZedSecure.ps1 with -DisableAi. Extra arguments are forwarded.

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage: Install-ZedNoAi.ps1 [OPTIONS]

Install Zed Secure with AI disabled (maximum privacy).
OPTIONS are forwarded to Install-ZedSecure.ps1 (e.g. -DryRun, -Channel, -Offline).

The preset always passes -DisableAi first; forwarded flags can change other behavior
(e.g. -Channel, -MergeConfig). AI stays disabled even if -LlmModel is passed.

Examples:
  .\Install-ZedNoAi.ps1
  .\Install-ZedNoAi.ps1 -DryRun
'@ | ForEach-Object { [Console]::Error.WriteLine($_) }
}

foreach ($a in $args) {
    if ($a -eq '-h' -or $a -eq '-Help' -or $a -eq '--help' -or $a -eq '/?') {
        Show-Usage
        exit 0
    }
}

$installer = Join-Path $PSScriptRoot 'Install-ZedSecure.ps1'
if (-not (Test-Path -LiteralPath $installer)) {
    [Console]::Error.WriteLine("ERROR: missing $installer")
    exit 1
}

& $installer -DisableAi @args
exit $LASTEXITCODE
