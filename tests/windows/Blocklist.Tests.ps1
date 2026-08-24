# Mirrors test_blocklist_idempotency.sh + test_disable_blocklist_only.sh, plus a real
# (non-elevated, temp-file) idempotency check of the privileged sub-script's hosts logic.
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'Endpoint blocklist (dry-run semantics)' {
    It 'repeated dry-run with -EnableEndpointBlocklist exits 0' {
        (Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-EnableEndpointBlocklist', '-DryRun')).ExitCode | Should -Be 0
        (Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-EnableEndpointBlocklist', '-DryRun')).ExitCode | Should -Be 0
    }
    It 'shows hosts-only semantics in dry-run' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-EnableEndpointBlocklist', '-DryRun')
        Should-ContainText $r.Output 'Would append hosts blocklist'
        Should-ContainText $r.Output 'Blocklist:  enabled (hosts only; no machine-wide rules)'
        Should-ContainText $r.Output 'hosts-only'
    }
}

Describe '-DisableEndpointBlocklist only' {
    It 'removes the blocklist without install side effects' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableEndpointBlocklist', '-DryRun')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output 'Would remove hosts blocklist markers'
        Should-ContainText $r.Output 'Endpoint blocklist removed'
        Should-NotContainText $r.Output 'Would write'
        Should-NotContainText $r.Output 'Installing Zed'
    }
    It 'with -DisableAi still exits without reinstall' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableEndpointBlocklist', '-DisableAi', '-DryRun')
        Should-ContainText $r.Output 'Endpoint blocklist removed'
        Should-NotContainText $r.Output 'Installing Zed'
    }
    It 'with -LlmModel still runs the install' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableEndpointBlocklist', '-LlmModel', 'test-model', '-DryRun')
        Should-ContainText $r.Output 'Installing Zed'
    }
}

Describe 'Invoke-ZedFirewallStep.ps1 hosts logic (real, temp file)' {
    It 'appends an idempotent marker block and removes it' {
        $hosts = Join-Path $TestDrive (([guid]::NewGuid().ToString()) + '-hosts')
        Set-Content -LiteralPath $hosts -Value "127.0.0.1 localhost" -NoNewline
        $args = @('-AddHostsBlocklist', '-HostsPath', $hosts, '-Domains', 'cloud.zed.dev,api.openai.com')
        Invoke-ZedScript -Script 'Invoke-ZedFirewallStep.ps1' -Arguments $args | Out-Null
        Invoke-ZedScript -Script 'Invoke-ZedFirewallStep.ps1' -Arguments $args | Out-Null
        $content = Get-Content -Raw -LiteralPath $hosts
        ([regex]::Matches($content, [regex]::Escape('# zed-secure-blocklist begin'))).Count | Should -Be 1
        $content | Should -Match ([regex]::Escape('0.0.0.0 cloud.zed.dev'))
        $content | Should -Match ([regex]::Escape('0.0.0.0 api.openai.com'))

        Invoke-ZedScript -Script 'Invoke-ZedFirewallStep.ps1' -Arguments @('-RemoveHostsBlocklist', '-HostsPath', $hosts) | Out-Null
        $after = Get-Content -Raw -LiteralPath $hosts
        $after | Should -Not -Match ([regex]::Escape('zed-secure-blocklist'))
        $after | Should -Match ([regex]::Escape('127.0.0.1 localhost'))
    }
}
