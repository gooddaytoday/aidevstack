# Mirrors test_offline_install.sh
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'Offline install via ZED_BUNDLE_PATH' {
    It 'uses the local bundle without winget in dry-run' {
        $bundle = Join-Path $TestDrive 'zed-windows-x86_64.zip'
        Set-Content -LiteralPath $bundle -Value 'stub' -NoNewline
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-Offline', '-DryRun') -EnvVars @{ ZED_BUNDLE_PATH = $bundle }
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output 'Installing Zed from local bundle'
        Should-ContainText $r.Output 'Expand-Archive'
        Should-NotContainText $r.Output 'winget install'
    }

    It '-Offline without a bundle is rejected' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-Offline', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'ZED_BUNDLE_PATH'
    }
}
