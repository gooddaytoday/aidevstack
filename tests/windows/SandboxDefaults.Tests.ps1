# Mirrors test_sandbox_defaults.sh
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'Network sandbox defaults (local-AI)' {
    It 'enables sandbox by default for a local-AI install' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-LlmModel', 'test-model', '-DryRun')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Sandbox:\s+enabled'
    }

    It '-NoNetworkSandbox warns and disables' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-LlmModel', 'test-model', '-NoNetworkSandbox', '-DryRun')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output 'Network sandbox DISABLED'
        $r.Output | Should -Match 'Sandbox:\s+disabled'
    }

    It '-DisableAi disables the sandbox' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-DryRun')
        $r.Output | Should -Match 'Sandbox:\s+disabled'
    }

    It 'respects ZED_LLM_MODEL from the environment' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DryRun') -EnvVars @{ ZED_LLM_MODEL = 'env-model' }
        $r.Output | Should -Match 'Sandbox:\s+enabled'
    }

    It 'rejects conflicting sandbox flags' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-LlmModel', 'm', '-EnableNetworkSandbox', '-NoNetworkSandbox', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
    }
}
