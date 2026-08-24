#Requires -Version 5.1
<#
.SYNOPSIS
  Standalone privacy-overlay enforcer (copied to %LOCALAPPDATA%\zed-secure and invoked by
  the zed-secure launcher on every Zed launch). Mirrors the standalone-invocation block of
  scripts/zed-security-settings.sh.
.NOTES
  Exit codes: 0 = full overlay applied, 2 = partial regex-only fix, 1 = failure.
  Set $env:ZED_ENFORCE_STRICT_VERIFY=1 to fail (exit 1) when verification does not pass.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Settings,
    [Parameter(Position = 1)][string]$Template = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ZedSecuritySettings.psm1') -Force

if (-not $Settings) { exit 1 }

# The share-dir template sits next to this helper (both copied to %LOCALAPPDATA%\zed-secure).
$share = Join-Path $PSScriptRoot 'settings-template.json'

$rc = Invoke-EnforceZedSettings -Settings $Settings -Template $Template -Share $share
if ($rc -eq 1) { exit 1 }

if (Test-ZedSecuritySettings -Path $Settings) {
    if ($rc -eq 2) { exit 2 }
    exit 0
}

if ($env:ZED_ENFORCE_STRICT_VERIFY -eq '1') { exit 1 }
if ($rc -eq 2) { exit 2 }
exit 0
