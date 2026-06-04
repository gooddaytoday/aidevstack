# Mirrors test_cli_parser.sh + test_force_config_removed.sh
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'CLI parser' {
    It 'rejects an unknown flag (non-zero exit)' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-TotallyUnknownFlag', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'TotallyUnknownFlag'
    }

    It '-LlmModel without a value fails' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-LlmModel')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'argument'
    }

    It '-Channel without a value fails' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-Channel')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'argument'
    }

    It '-Help exits 0 and lists key flags' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-Help')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output '-DisableAi'
        Should-ContainText $r.Output '-LlmModel'
        Should-ContainText $r.Output '-MergeConfig'
    }

    It 'rejects the removed -ForceConfig (R7 regression)' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-ForceConfig', '-DisableAi', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'ForceConfig'
    }

    It '-Help does not mention force-config' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-Help')
        ($r.Output -match 'force-config') | Should -BeFalse
        ($r.Output -match 'ForceConfig') | Should -BeFalse
    }
}
