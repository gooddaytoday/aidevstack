# Real-mode installs into an isolated env with a stub Zed.exe (no winget/admin needed).
# Mirrors the install/overlay/repair behaviors of test_json_generation.sh (cases 10/11),
# test_security_enforce.sh, test_write_settings_jsonc.sh, and test_agent_permissions_disable_ai.sh.
BeforeAll {
    . (Join-Path $PSScriptRoot '_Common.ps1')
    Import-Module $ModulePath -Force

    function New-FullEnv {
        param([string]$Root)
        $e = New-ZedTestEnv -Root $Root -SeedZed
        foreach ($k in 'USERPROFILE', 'ProgramData', 'PUBLIC') {
            $p = Join-Path $Root $k
            New-Item -ItemType Directory -Force -Path $p | Out-Null
            $e[$k] = $p
        }
        return $e
    }
    function Read-Settings { param([hashtable]$EnvVars) ConvertFrom-JsoncFile (Get-ZedSettingsPath $EnvVars) }
}

Describe 'Install onto existing settings' {
    It 'security-only overlay preserves custom keys and user language_models (disable-ai)' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        $settings = Get-ZedSettingsPath $e
        Set-Content -LiteralPath $settings -NoNewline -Value '{ "custom_theme":"keep-me", "telemetry":{"metrics":true,"diagnostics":true}, "language_models":{"openai_compatible":{"GPUStack":{"api_url":"http://gpu.local/v1"}}} }'
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi') -EnvVars $e
        $r.ExitCode | Should -Be 0
        $s = Read-Settings $e
        $s.telemetry.metrics | Should -BeFalse
        $s.custom_theme | Should -Be 'keep-me'
        $s.language_models.openai_compatible.GPUStack.api_url | Should -Be 'http://gpu.local/v1'
        (Test-Path -LiteralPath (Join-Path (Split-Path $settings) 'settings.zed-secure-template.json')) | Should -BeTrue
    }

    It 'merge-config overwrites security keys, drops stale nested keys, preserves user keys' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        $settings = Get-ZedSettingsPath $e
        Set-Content -LiteralPath $settings -NoNewline -Value '{ "custom_theme":"user-dark", "telemetry":{"metrics":true,"diagnostics":true,"extra_old":true}, "title_bar":{"show_sign_in":true}, "editor":{"tab_size":4} }'
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-MergeConfig') -EnvVars $e
        $r.ExitCode | Should -Be 0
        $s = Read-Settings $e
        $s.telemetry.metrics | Should -BeFalse
        $s.disable_ai | Should -BeTrue
        $s.title_bar.show_sign_in | Should -BeFalse
        $s.custom_theme | Should -Be 'user-dark'
        $s.editor.tab_size | Should -Be 4
        ($s.telemetry.PSObject.Properties['extra_old']) | Should -BeNullOrEmpty
    }

    It 'merge-config overwrites permissive agent permissions' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        $settings = Get-ZedSettingsPath $e
        Set-Content -LiteralPath $settings -NoNewline -Value '{ "custom_key":true, "agent":{"tool_permissions":{"default":"allow","tools":{"fetch":{"default":"allow"}}}} }'
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-MergeConfig') -EnvVars $e
        $r.ExitCode | Should -Be 0
        $s = Read-Settings $e
        $s.agent.tool_permissions.tools.fetch.default | Should -Be 'deny'
        $s.custom_key | Should -BeTrue
    }

    It 'refresh-llm replaces language_models and keeps custom_theme' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        $settings = Get-ZedSettingsPath $e
        Set-Content -LiteralPath $settings -NoNewline -Value '{ "custom_theme":"my-theme", "telemetry":{"metrics":true,"diagnostics":true}, "language_models":{"openai_compatible":{"Old":{"api_url":"http://old/v1"}}} }'
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-LlmModel', 'test-model', '-RefreshLlmConfig', '-NoNetworkSandbox') -EnvVars $e
        $r.ExitCode | Should -Be 0
        $s = Read-Settings $e
        $s.custom_theme | Should -Be 'my-theme'
        ($s.language_models.openai_compatible.PSObject.Properties['Old']) | Should -BeNullOrEmpty
        $s.language_models.openai_compatible.LocalLLM.available_models[0].name | Should -Be 'test-model'
    }
}

Describe 'Fresh install (disable-ai)' {
    It 'writes a valid settings.json with agent permissions and telemetry off' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi') -EnvVars $e
        $r.ExitCode | Should -Be 0
        $s = Read-Settings $e
        $s | Should -Not -BeNullOrEmpty
        $s.disable_ai | Should -BeTrue
        $s.agent.tool_permissions.tools.fetch.default | Should -Be 'deny'
        $s.agent.tool_permissions.tools.search_web.default | Should -Be 'deny'
        $s.telemetry.metrics | Should -BeFalse
    }
}

Describe '-RepairSettings' {
    It 'infers disable_ai from settings when the template is missing' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        $settings = Get-ZedSettingsPath $e
        Set-Content -LiteralPath $settings -NoNewline -Value '{ "disable_ai": true, "telemetry": { "metrics": true, "diagnostics": true }, "auto_update": true }'
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-RepairSettings') -EnvVars $e
        $r.ExitCode | Should -Be 0
        $s = Read-Settings $e
        $s.telemetry.metrics | Should -BeFalse
        $s.disable_ai | Should -BeTrue
        $tpl = ConvertFrom-JsoncFile (Join-Path (Split-Path $settings) 'settings.zed-secure-template.json')
        $tpl.disable_ai | Should -BeTrue
    }

    It 'fails on unreadable settings with no template' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        Set-Content -LiteralPath (Get-ZedSettingsPath $e) -NoNewline -Value '{ broken json'
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-RepairSettings') -EnvVars $e
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'Launcher + enforce helper' {
    It 'embeds env-clear + enforce hook and installs the helper' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi') -EnvVars $e
        $r.ExitCode | Should -Be 0
        $launcher = Join-Path $e.LOCALAPPDATA 'zed-secure\ZedSecureLauncher.ps1'
        (Test-Path -LiteralPath $launcher) | Should -BeTrue
        $body = Get-Content -Raw -LiteralPath $launcher
        $body | Should -Match ([regex]::Escape('ZED_SECURE_ENFORCE_SETTINGS'))
        $body | Should -Match ([regex]::Escape('Enforce-ZedSettings.ps1'))
        $body | Should -Match ([regex]::Escape('OPENAI_API_KEY'))
        (Test-Path -LiteralPath (Join-Path $e.LOCALAPPDATA 'zed-secure\Enforce-ZedSettings.ps1')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $e.LOCALAPPDATA 'zed-secure\ZedSecuritySettings.psm1')) | Should -BeTrue
    }

    It 'the enforce helper fixes telemetry on launch (E2E)' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $e = New-FullEnv $root
        (Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi') -EnvVars $e).ExitCode | Should -Be 0
        $settings = Get-ZedSettingsPath $e
        $template = Join-Path (Split-Path $settings) 'settings.zed-secure-template.json'
        Set-Content -LiteralPath $settings -NoNewline -Value '{ "telemetry": { "metrics": true, "diagnostics": true }, "auto_update": true }'
        $helper = Join-Path $e.LOCALAPPDATA 'zed-secure\Enforce-ZedSettings.ps1'
        $exe = Get-PwshExe
        & $exe -NoProfile -ExecutionPolicy Bypass -File $helper $settings $template | Out-Null
        $rc = $LASTEXITCODE
        $rc | Should -Be 0
        (Read-Settings $e).telemetry.metrics | Should -BeFalse
    }
}
