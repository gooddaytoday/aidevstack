# Mirrors test_merge_config.sh + test_security_enforce.sh + test_write_settings_jsonc.sh
# (the in-process overlay/enforce/verify/infer logic).
BeforeAll {
    . (Join-Path $PSScriptRoot '_Common.ps1')
    Import-Module $ModulePath -Force

    function New-Template {
        param([bool]$DisableAi = $true, [string]$Model = '')
        New-ZedSettingsObject -DisableAi $DisableAi -DoNotHideEnvFiles $false `
            -DisableLocalEditPredictions $false -LlmProviderName 'LocalLLM' `
            -LlmApiUrl 'http://127.0.0.1:8080/v1' -LlmModel $Model -LlmCompletionsUrl 'http://127.0.0.1:8080/v1/completions'
    }

    function Write-TemplateFile {
        param([string]$Path, [bool]$DisableAi = $true, [string]$Model = '')
        Write-Utf8NoBom -Path $Path -Text (ConvertTo-ZedJson (New-Template -DisableAi $DisableAi -Model $Model))
    }
}

Describe 'Merge-ZedOverlay (deep merge then forced overwrite)' {
    It 'merge-config: telemetry.extra_old dropped, custom + editor preserved, security overwritten' {
        $existing = '{ "custom_theme":"user-dark", "telemetry":{"metrics":true,"diagnostics":true,"extra_old":true}, "title_bar":{"show_sign_in":true}, "editor":{"tab_size":4} }' | ConvertFrom-Json
        $template = New-Template -DisableAi $true
        # Template is an ordered dict; round-trip to PSCustomObject as enforce does (read from file).
        $template = (ConvertTo-ZedJson $template) | ConvertFrom-Json
        $r = Merge-ZedOverlay -Existing $existing -Template $template -RefreshLlm $true
        $r.telemetry.metrics | Should -BeFalse
        ($r.telemetry.PSObject.Properties['extra_old']) | Should -BeNullOrEmpty
        $r.title_bar.show_sign_in | Should -BeFalse
        $r.custom_theme | Should -Be 'user-dark'
        $r.editor.tab_size | Should -Be 4
        $r.disable_ai | Should -BeTrue
        $r.auto_update | Should -BeFalse
    }

    It 'security-only: preserves user language_models when template has none (disable-ai)' {
        $existing = '{ "custom_marker":"stay", "telemetry":{"metrics":true,"diagnostics":true}, "language_models":{"openai_compatible":{"GPUStack":{"api_url":"http://gpu.local/v1"}}} }' | ConvertFrom-Json
        $template = (ConvertTo-ZedJson (New-Template -DisableAi $true)) | ConvertFrom-Json
        $r = Merge-ZedOverlay -Existing $existing -Template $template -RefreshLlm $false
        $r.telemetry.metrics | Should -BeFalse
        $r.custom_marker | Should -Be 'stay'
        $r.language_models.openai_compatible.GPUStack.api_url | Should -Be 'http://gpu.local/v1'
    }

    It 'refresh-llm: replaces language_models (drops Old, sets LocalLLM), keeps custom_theme' {
        $existing = '{ "custom_theme":"my-theme", "telemetry":{"metrics":true,"diagnostics":true}, "language_models":{"openai_compatible":{"Old":{"api_url":"http://old/v1"}}} }' | ConvertFrom-Json
        $template = (ConvertTo-ZedJson (New-Template -DisableAi $false -Model 'test-model')) | ConvertFrom-Json
        $r = Merge-ZedOverlay -Existing $existing -Template $template -RefreshLlm $true
        $r.custom_theme | Should -Be 'my-theme'
        ($r.language_models.openai_compatible.PSObject.Properties['Old']) | Should -BeNullOrEmpty
        $r.language_models.openai_compatible.LocalLLM.available_models[0].name | Should -Be 'test-model'
    }

    It 'agent permissions overwritten from template (permissive -> deny)' {
        $existing = '{ "custom_key":true, "agent":{"tool_permissions":{"default":"allow","tools":{"fetch":{"default":"allow"}}}} }' | ConvertFrom-Json
        $template = (ConvertTo-ZedJson (New-Template -DisableAi $true)) | ConvertFrom-Json
        $r = Merge-ZedOverlay -Existing $existing -Template $template -RefreshLlm $true
        $r.agent.tool_permissions.tools.fetch.default | Should -Be 'deny'
        $r.custom_key | Should -BeTrue
    }
}

Describe 'Invoke-EnforceZedSettings exit-code contract' {
    It 'returns 0 and applies overlay on valid settings + template' {
        $settings = Join-Path $TestDrive 'enf0.json'
        $tpl = Join-Path $TestDrive 'tpl0.json'
        Write-TemplateFile -Path $tpl -DisableAi $true
        Write-Utf8NoBom -Path $settings -Text '{ "custom_theme":"keep", "telemetry":{"metrics":true,"diagnostics":true} }'
        $rc = Invoke-EnforceZedSettings -Settings $settings -Template $tpl -Share 'C:\nonexistent\share.json'
        $rc | Should -Be 0
        $obj = ConvertFrom-JsoncFile $settings
        $obj.telemetry.metrics | Should -BeFalse
        $obj.custom_theme | Should -Be 'keep'
    }

    It 'normalizes JSONC (trailing commas) before overlay' {
        $settings = Join-Path $TestDrive 'enfjsonc.json'
        $tpl = Join-Path $TestDrive 'tpljsonc.json'
        Write-TemplateFile -Path $tpl -DisableAi $true
        Write-Utf8NoBom -Path $settings -Text "{`n  `"terminal`": { `"font_size`": 16, },`n  `"custom_theme`": `"keep-jsonc`",`n  `"telemetry`": { `"diagnostics`": true, `"metrics`": true },`n}"
        $rc = Invoke-EnforceZedSettings -Settings $settings -Template $tpl
        $rc | Should -Be 0
        $obj = ConvertFrom-JsoncFile $settings
        $obj.telemetry.metrics | Should -BeFalse
        $obj.custom_theme | Should -Be 'keep-jsonc'
    }

    It 'returns 2 (regex-only) when settings unparseable and no template' {
        $settings = Join-Path $TestDrive 'enf2.json'
        Write-Utf8NoBom -Path $settings -Text "{ `"telemetry`": { `"diagnostics`": true, `"metrics`": true, }, `"x`": [1,2, }"
        $rc = Invoke-EnforceZedSettings -Settings $settings -Template 'C:\nope\t.json' -Share 'C:\nope\s.json'
        $rc | Should -Be 2
    }

    It 'returns 1 when neither settings nor template exist' {
        $rc = Invoke-EnforceZedSettings -Settings (Join-Path $TestDrive 'missing.json') -Template 'C:\nope\t.json' -Share 'C:\nope\s.json'
        $rc | Should -Be 1
    }

    It 'uses the share-dir template when the primary is missing' {
        $settings = Join-Path $TestDrive 'enfshare.json'
        $share = Join-Path $TestDrive 'share-template.json'
        Write-TemplateFile -Path $share -DisableAi $true
        Write-Utf8NoBom -Path $settings -Text '{ "telemetry": { "diagnostics": true, "metrics": true } }'
        $rc = Invoke-EnforceZedSettings -Settings $settings -Template 'C:\nope\t.json' -Share $share
        $rc | Should -Be 0
        (ConvertFrom-JsoncFile $settings).telemetry.metrics | Should -BeFalse
    }
}

Describe 'Test-ZedSecuritySettings + Repair-ZedPrivacyByRegex' {
    It 'verifies telemetry + auto_update are false' {
        $f = Join-Path $TestDrive 'verify.json'
        Write-Utf8NoBom -Path $f -Text '{ "telemetry": { "metrics": false, "diagnostics": false }, "auto_update": false }'
        Test-ZedSecuritySettings -Path $f | Should -BeTrue
        Write-Utf8NoBom -Path $f -Text '{ "telemetry": { "metrics": true, "diagnostics": false }, "auto_update": false }'
        Test-ZedSecuritySettings -Path $f | Should -BeFalse
    }

    It 'regex fallback flips the four keys in unparseable JSONC' {
        $f = Join-Path $TestDrive 'fallback.json'
        Write-Utf8NoBom -Path $f -Text "{ `"telemetry`": { `"diagnostics`": true, `"metrics`": true, }, }"
        Repair-ZedPrivacyByRegex $f | Should -BeTrue
        (Get-Content -Raw $f) | Should -Match ([regex]::Escape('"metrics": false'))
    }

    It 'rejects malformed settings regardless of security-looking literals' {
        $f = Join-Path $TestDrive 'verify-raw.json'
        Write-Utf8NoBom -Path $f -Text '{ "telemetry": { "metrics": false, "diagnostics": false }, "auto_update": null, "broken": [1, }'
        Test-ZedSecuritySettings -Path $f | Should -BeFalse

        Write-Utf8NoBom -Path $f -Text '{ "telemetry": { "metrics": false, "diagnostics": false }, "auto_update": false, "broken": [1, }'
        Test-ZedSecuritySettings -Path $f | Should -BeFalse

        Write-Utf8NoBom -Path $f -Text '{ "telemetry": { "metrics": false, "diagnostics": false }, "auto_update": falsehood, "broken": [1, }'
        Test-ZedSecuritySettings -Path $f | Should -BeFalse
    }
}

Describe 'Get-InferredZedInstallMode' {
    It 'infers disable-ai from settings' {
        $f = Join-Path $TestDrive 'infer1.json'
        Write-Utf8NoBom -Path $f -Text '{ "disable_ai": true, "telemetry": { "metrics": true } }'
        (Get-InferredZedInstallMode $f).DisableAi | Should -BeTrue
    }

    It 'infers local LLM provider/model from settings' {
        $f = Join-Path $TestDrive 'infer2.json'
        Write-Utf8NoBom -Path $f -Text '{ "language_models": { "openai_compatible": { "MyProv": { "api_url": "http://127.0.0.1:9/v1", "available_models": [ { "name": "mm" } ] } } } }'
        $m = Get-InferredZedInstallMode $f
        $m.DisableAi | Should -BeFalse
        $m.Provider | Should -Be 'MyProv'
        $m.Model | Should -Be 'mm'
    }

    It 'returns $null for unrecoverable settings' {
        $f = Join-Path $TestDrive 'infer3.json'
        Write-Utf8NoBom -Path $f -Text '{ broken json'
        Get-InferredZedInstallMode $f | Should -BeNullOrEmpty
    }
}
