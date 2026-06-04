# Mirrors test_dry_run.sh
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'Dry-run is non-destructive' {
    It 'prints [dry-run] markers and leaves existing settings unchanged' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $env1 = New-ZedTestEnv -Root $root
        $settings = Get-ZedSettingsPath $env1
        Set-Content -LiteralPath $settings -Value '{"unchanged":true}' -NoNewline
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-DryRun') -EnvVars $env1
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output '[dry-run]'
        (Get-Content -Raw -LiteralPath $settings) | Should -Be '{"unchanged":true}'
    }

    It 'does not create settings.json when absent' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $env1 = New-ZedTestEnv -Root $root
        $settings = Get-ZedSettingsPath $env1
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-DryRun') -EnvVars $env1
        $r.ExitCode | Should -Be 0
        (Test-Path -LiteralPath $settings) | Should -BeFalse
    }

    It 'endpoint blocklist dry-run is non-destructive' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $env1 = New-ZedTestEnv -Root $root
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-EnableEndpointBlocklist', '-DryRun') -EnvVars $env1
        Should-ContainText $r.Output 'Would append hosts blocklist'
        Should-NotContainText $r.Output 'Applied hosts blocklist'
        (Test-Path -LiteralPath $env1.ZED_SECURE_HOSTS_PATH) | Should -BeFalse
    }
}
