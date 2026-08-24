# Mirrors test_json_generation.sh (settings structure) + JSONC normalization, in-process.
BeforeAll {
    . (Join-Path $PSScriptRoot '_Common.ps1')
    Import-Module $ModulePath -Force
}

Describe 'New-ZedSettingsObject + ConvertTo-ZedJson' {
    BeforeAll {
        function Get-Parsed {
            param([hashtable]$Parameters)
            $obj = New-ZedSettingsObject @Parameters
            $json = ConvertTo-ZedJson $obj
            # The serializer output must be valid JSON.
            return ($json | ConvertFrom-Json)
        }
    }

    It 'case 1: -DisableAi sets disable_ai true' {
        $p = Get-Parsed @{ DisableAi = $true }
        $p.disable_ai | Should -BeTrue
    }

    It 'case 2: language_models with full capabilities (single-element available_models[0] survives)' {
        $p = Get-Parsed @{ DisableAi = $false; LlmModel = 'test-model' }
        $p.language_models.openai_compatible.LocalLLM.available_models[0].name | Should -Be 'test-model'
        $p.language_models.openai_compatible.LocalLLM.available_models[0].capabilities.parallel_tool_calls | Should -BeFalse
        $p.language_models.openai_compatible.LocalLLM.available_models[0].capabilities.prompt_cache_key | Should -BeFalse
    }

    It 'case 3: -DisableLocalEditPredictions sets show_edit_predictions false' {
        $p = Get-Parsed @{ DisableAi = $false; LlmModel = 'm'; DisableLocalEditPredictions = $true }
        $p.show_edit_predictions | Should -BeFalse
        $p.edit_predictions.provider | Should -Be 'none'
    }

    It 'case 4: -DoNotHideEnvFiles omits **/.env*' {
        $p = Get-Parsed @{ DisableAi = $true; DoNotHideEnvFiles = $true }
        ($p.file_scan_exclusions -contains '**/.env*') | Should -BeFalse
    }

    It 'case 5: default hides **/.env*' {
        $p = Get-Parsed @{ DisableAi = $true }
        ($p.file_scan_exclusions -contains '**/.env*') | Should -BeTrue
    }

    It 'case 6: agent fetch/search_web denied even with -DisableAi' {
        $p = Get-Parsed @{ DisableAi = $true }
        $p.agent.tool_permissions.tools.fetch.default | Should -Be 'deny'
        $p.agent.tool_permissions.tools.search_web.default | Should -Be 'deny'
    }

    It 'case 7: telemetry disabled' {
        $p = Get-Parsed @{ DisableAi = $true }
        $p.telemetry.metrics | Should -BeFalse
        $p.telemetry.diagnostics | Should -BeFalse
    }

    It 'case 8: title_bar.show_sign_in false' {
        $p = Get-Parsed @{ DisableAi = $true }
        $p.title_bar.show_sign_in | Should -BeFalse
    }

    It 'case 9: query URL preserved' {
        $p = Get-Parsed @{ DisableAi = $false; LlmModel = 'm'; LlmApiUrl = 'http://127.0.0.1:8080/v1?api_version=2024' }
        $p.language_models.openai_compatible.LocalLLM.api_url | Should -Be 'http://127.0.0.1:8080/v1?api_version=2024'
    }

    It 'agent always_deny regex patterns round-trip through the serializer' {
        $p = Get-Parsed @{ DisableAi = $true }
        $p.agent.tool_permissions.tools.terminal.always_deny[0].pattern |
            Should -Be 'api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|cloud\.zed\.dev'
        $p.agent.tool_permissions.tools.edit_file.always_deny[0].pattern | Should -Be '\.env'
        $p.agent.tool_permissions.tools.edit_file.always_deny[2].pattern | Should -Be '\.(pem|key|crt|p12)$'
    }

    It 'numbers stay numeric (max_tokens, max_output_tokens)' {
        $p = Get-Parsed @{ DisableAi = $false; LlmModel = 'm' }
        $p.language_models.openai_compatible.LocalLLM.available_models[0].max_tokens | Should -Be 32768
        $p.edit_predictions.open_ai_compatible_api.max_output_tokens | Should -Be 512
    }
}

Describe 'JSONC normalization' {
    It 'strips // and /* */ comments, removes trailing commas, parses' {
        $jsonc = @'
{
  // a comment with http://not-a-url inside
  "custom_theme": "keep", /* block */
  "telemetry": { "diagnostics": true, "metrics": true, },
}
'@
        $obj = ConvertFrom-JsoncText $jsonc
        $obj | Should -Not -BeNullOrEmpty
        $obj.custom_theme | Should -Be 'keep'
        $obj.telemetry.metrics | Should -BeTrue
    }

    It 'preserves http:// inside string values (regression)' {
        $jsonc = '{ "api_url": "http://127.0.0.1:8080/v1", "b": 1, }'
        $obj = ConvertFrom-JsoncText $jsonc
        $obj.api_url | Should -Be 'http://127.0.0.1:8080/v1'
    }

    It 'preserves comment-like sequences inside strings' {
        $jsonc = '{ "a": "x // y /* z */ w", "b": 2 }'
        $obj = ConvertFrom-JsoncText $jsonc
        $obj.a | Should -Be 'x // y /* z */ w'
    }

    It 'returns $null for unrecoverable JSON' {
        ConvertFrom-JsoncText '{ broken json' | Should -BeNullOrEmpty
    }
}

Describe 'Write-Utf8NoBom' {
    It 'writes UTF-8 without a BOM' {
        $f = Join-Path $TestDrive 'nobom.json'
        Write-Utf8NoBom -Path $f -Text '{"a":1}'
        $bytes = [System.IO.File]::ReadAllBytes($f)
        # BOM would be EF BB BF
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}
