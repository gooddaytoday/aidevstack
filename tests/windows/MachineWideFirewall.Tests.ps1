# Mirrors test_uid_firewall_confirm.sh (Windows machine-wide strict firewall confirm guardrails)
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'Machine-wide strict firewall confirm guardrails' {
    It '-MachineWideStrictFirewall without accept is rejected' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-MachineWideStrictFirewall', '-DisableAi', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output '-IAcceptMachineWideFirewall'
    }

    It '-IAcceptMachineWideFirewall without the main flag is rejected' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-IAcceptMachineWideFirewall', '-DisableAi', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'requires -MachineWideStrictFirewall'
    }

    It 'both flags + dry-run succeeds and previews the rule' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-MachineWideStrictFirewall', '-IAcceptMachineWideFirewall', '-DisableAi', '-DryRun')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output 'Would create firewall rules blocking outbound'
    }

    It '-Help lists the firewall confirm flags' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-Help')
        Should-ContainText $r.Output '-MachineWideStrictFirewall'
        Should-ContainText $r.Output '-IAcceptMachineWideFirewall'
        Should-ContainText $r.Output '-Yes'
    }
}
