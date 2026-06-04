# Mirrors test_preset_installers.sh
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'Install-ZedNoAi.ps1' {
    It '-Help exits 0' {
        (Invoke-ZedScript -Script 'Install-ZedNoAi.ps1' -Arguments @('-Help')).ExitCode | Should -Be 0
    }
    It 'dry-run keeps AI disabled' {
        $r = Invoke-ZedScript -Script 'Install-ZedNoAi.ps1' -Arguments @('-DryRun')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output '[dry-run]'
        Should-ContainText $r.Output 'AI mode:    disabled'
    }
    It 'keeps AI disabled even with a forwarded -LlmModel' {
        $r = Invoke-ZedScript -Script 'Install-ZedNoAi.ps1' -Arguments @('-LlmModel', 'evil', '-DryRun')
        Should-ContainText $r.Output 'AI mode:    disabled'
    }
    It 'forwards -Channel' {
        $r = Invoke-ZedScript -Script 'Install-ZedNoAi.ps1' -Arguments @('-Channel', 'preview', '-DryRun')
        Should-ContainText $r.Output 'channel=preview'
        Should-ContainText $r.Output 'Zed Preview'
    }
}

Describe 'Install-ZedLocalLlm.ps1' {
    It '-Help exits 0' {
        (Invoke-ZedScript -Script 'Install-ZedLocalLlm.ps1' -Arguments @('-Help')).ExitCode | Should -Be 0
    }
    It 'requires a MODEL argument' {
        $r = Invoke-ZedScript -Script 'Install-ZedLocalLlm.ps1' -Arguments @()
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'MODEL must be the first argument'
    }
    It 'rejects a flag in the MODEL position' {
        $r = Invoke-ZedScript -Script 'Install-ZedLocalLlm.ps1' -Arguments @('-DryRun')
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'cannot start with "-"'
        Should-ContainText $r.Output 'your-model-name -DryRun'
    }
    It 'installs with model + sandbox + blocklist preset (dry-run)' {
        $r = Invoke-ZedScript -Script 'Install-ZedLocalLlm.ps1' -Arguments @('test-model', '-DryRun')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output '[dry-run]'
        Should-ContainText $r.Output 'LLM model:  test-model'
        Should-ContainText $r.Output 'AI mode:    local OpenAI-compatible'
        $r.Output | Should -Match 'Sandbox:\s+enabled'
        Should-ContainText $r.Output 'hosts blocklist'
    }
}
