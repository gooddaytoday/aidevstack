#Requires -Version 5.1
<#
.SYNOPSIS
  Windows test runner (analog of tests/run.sh): parse-checks every script, runs the Pester
  suite, then runs PSScriptAnalyzer (non-fatal, like the Linux ShellCheck step).
#>
[CmdletBinding()]
param([switch]$SkipAnalyzer)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ScriptsDir = Join-Path $RepoRoot 'scripts\windows'
$TestsDir = $PSScriptRoot

Write-Host '==> Syntax check (PowerShell parser)'
$failed = 0
$files = @()
$files += Get-ChildItem -Path $ScriptsDir -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path $TestsDir -Recurse -Include '*.ps1' -ErrorAction SilentlyContinue
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed++
        Write-Host "SYNTAX FAIL: $($f.FullName)"
        foreach ($e in $errors) { Write-Host "   $($e.Message)" }
    } else {
        Write-Host "ok: $($f.Name)"
    }
}
if ($failed -gt 0) {
    Write-Host "$failed file(s) failed the syntax check."
    exit 1
}

Write-Host ''
Write-Host '==> Pester'
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$cfg = New-PesterConfiguration
$cfg.Run.Path = $TestsDir
$cfg.Run.Exit = $false
$cfg.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $cfg
if ($result.FailedCount -gt 0) {
    Write-Host "$($result.FailedCount) test(s) failed."
    exit 1
}

if (-not $SkipAnalyzer) {
    Write-Host ''
    Write-Host '==> PSScriptAnalyzer (non-fatal)'
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        $issues = Invoke-ScriptAnalyzer -Path $ScriptsDir -Recurse -Severity Error, Warning -ErrorAction SilentlyContinue
        if ($issues) {
            $issues | Format-Table -AutoSize | Out-String | Write-Host
        } else {
            Write-Host 'PSScriptAnalyzer: no Error/Warning findings.'
        }
    } else {
        Write-Host 'PSScriptAnalyzer not installed; skipping (non-fatal).'
    }
}

Write-Host ''
Write-Host 'All Windows tests passed.'
exit 0
