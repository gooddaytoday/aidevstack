#Requires -Version 5.1
<#
.SYNOPSIS
  Privileged step for Install-ZedSecure.ps1: per-app firewall rule, machine-wide strict
  firewall, and hosts-file blocklist. Run elevated (UAC) by the main installer, or directly.
.DESCRIPTION
  Isolated so that UAC elevation only covers the operations that actually require admin
  (firewall rules + %SystemRoot%\System32\drivers\etc\hosts). Honors -DryRun: with it, no
  changes are made and no elevation should ever be requested by the caller.
#>
[CmdletBinding()]
param(
    [string]$ZedExe = '',
    [string]$HostsPath = '',
    [string]$RuleGroup = 'zed-secure',
    [string]$StrictGroup = 'zed-secure-strict',
    [string]$Domains = '',
    [switch]$AddEgressRule,
    [switch]$RemoveEgressRule,
    [switch]$AddHostsBlocklist,
    [switch]$RemoveHostsBlocklist,
    [switch]$StrictFirewall,
    [switch]$RemoveStrictFirewall,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:MarkerBegin = '# zed-secure-blocklist begin'
$script:MarkerEnd = '# zed-secure-blocklist end'

function Write-StepLog  { param([string]$m) [Console]::Out.WriteLine("==> $m") }
function Write-StepWarn { param([string]$m) [Console]::Error.WriteLine("WARNING: $m") }

function Invoke-DnsFlush {
    try { & ipconfig /flushdns | Out-Null } catch { }
}

function Set-EgressRule {
    if ($DryRun) {
        Write-StepLog "[dry-run] New-NetFirewallRule (block outbound for $ZedExe, loopback allowed)"
        return
    }
    Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'zed-secure-block-egress' -Group $RuleGroup -Program $ZedExe `
        -Direction Outbound -Action Block -Profile Any -Enabled True | Out-Null
    Write-StepLog "Created firewall egress block rule for $ZedExe (loopback allowed)"
}

function Remove-EgressRule {
    if ($DryRun) {
        Write-StepLog "[dry-run] remove firewall group $RuleGroup"
        return
    }
    Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-StepLog "Removed firewall egress rule(s) ($RuleGroup)"
}

function Set-StrictRule {
    if ($DryRun) {
        Write-StepLog "[dry-run] New-NetFirewallRule (block ALL outbound machine-wide; loopback exempt)"
        return
    }
    Get-NetFirewallRule -Group $StrictGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'zed-secure-strict-block-all' -Group $StrictGroup `
        -Direction Outbound -Action Block -Profile Any -Enabled True | Out-Null
    Write-StepLog "Created machine-wide strict outbound block (loopback exempt)"
}

function Remove-StrictRule {
    if ($DryRun) {
        Write-StepLog "[dry-run] remove firewall group $StrictGroup"
        return
    }
    Get-NetFirewallRule -Group $StrictGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-StepLog "Removed machine-wide strict firewall ($StrictGroup)"
}

function Add-HostsBlocklistEntries {
    if (-not $HostsPath) { return }
    $domainList = @()
    if ($Domains) { $domainList = @($Domains -split ',' | Where-Object { $_ }) }
    if ($DryRun) {
        Write-StepLog "[dry-run] append hosts blocklist to $HostsPath"
        return
    }
    $content = if (Test-Path -LiteralPath $HostsPath) { [System.IO.File]::ReadAllText($HostsPath) } else { '' }
    if ($content -match [regex]::Escape($script:MarkerBegin)) {
        Write-StepLog "hosts blocklist already present (idempotent no-op)"
        return
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($script:MarkerBegin)
    foreach ($d in $domainList) { [void]$sb.AppendLine("0.0.0.0 $d") }
    [void]$sb.AppendLine($script:MarkerEnd)
    $newContent = $content
    if ($newContent.Length -gt 0 -and -not $newContent.EndsWith("`n")) { $newContent += "`r`n" }
    $newContent += $sb.ToString()
    [System.IO.File]::WriteAllText($HostsPath, $newContent, (New-Object System.Text.UTF8Encoding $false))
    Invoke-DnsFlush
    Write-StepLog "Applied hosts blocklist ($HostsPath)"
}

function Remove-HostsBlocklistEntries {
    if (-not $HostsPath) { return }
    if ($DryRun) {
        Write-StepLog "[dry-run] remove hosts blocklist markers from $HostsPath"
        return
    }
    if (-not (Test-Path -LiteralPath $HostsPath)) { return }
    $lines = [System.IO.File]::ReadAllLines($HostsPath)
    $out = New-Object System.Collections.ArrayList
    $skip = $false
    foreach ($ln in $lines) {
        if ($ln.Trim() -eq $script:MarkerBegin) { $skip = $true; continue }
        if ($ln.Trim() -eq $script:MarkerEnd) { $skip = $false; continue }
        if (-not $skip) { [void]$out.Add($ln) }
    }
    $text = ($out -join "`r`n")
    if ($text.Length -gt 0) { $text += "`r`n" }
    [System.IO.File]::WriteAllText($HostsPath, $text, (New-Object System.Text.UTF8Encoding $false))
    Invoke-DnsFlush
    Write-StepLog "Removed hosts blocklist markers ($HostsPath)"
}

function Invoke-FirewallStepMain {
    if ($AddEgressRule) { Set-EgressRule }
    if ($AddHostsBlocklist) { Add-HostsBlocklistEntries }
    if ($StrictFirewall) { Set-StrictRule }
    if ($RemoveEgressRule) { Remove-EgressRule }
    if ($RemoveHostsBlocklist) { Remove-HostsBlocklistEntries }
    if ($RemoveStrictFirewall) { Remove-StrictRule }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-FirewallStepMain
    exit 0
}
