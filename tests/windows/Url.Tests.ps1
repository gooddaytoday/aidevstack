# Mirrors test_url_validation.sh
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'LLM URL validation' {
    function Run-Url { param([string]$Url, [string[]]$Extra = @())
        Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments (@('-LlmModel', 'test-model', '-LlmApiUrl', $Url, '-DryRun') + $Extra)
    }

    It 'accepts loopback URLs' -ForEach @(
        @{ Url = 'http://127.0.0.1:8080/v1' }
        @{ Url = 'http://127.0.0.1/v1' }
        @{ Url = 'http://localhost:8080/v1' }
        @{ Url = 'http://[::1]:8080/v1' }
        @{ Url = 'http://[::1]/v1' }
        @{ Url = 'http://127.0.0.1:8080/v1?api_version=2024' }
        @{ Url = 'http://127.0.0.1:8080/v1?a=1&b=2' }
        @{ Url = 'http://127.0.0.1:8080/v1?key=hello%20world' }
        @{ Url = 'http://[::1]:8080/v1?api_version=2024' }
    ) {
        (Run-Url -Url $Url).ExitCode | Should -Be 0
    }

    It 'rejects non-loopback URLs with a loopback error' -ForEach @(
        @{ Url = 'http://192.168.1.1:8080/v1' }
        @{ Url = 'http://evil.com/v1' }
        @{ Url = 'http://evil.com/v1?foo=bar' }
    ) {
        $r = Run-Url -Url $Url
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'must be loopback'
    }

    It 'rejects invalid characters' -ForEach @(
        @{ Url = 'http://127.0.0.1:8080/v1?key=hello world' }
        @{ Url = 'http://user@127.0.0.1:8080/v1' }
        @{ Url = 'http://127.0.0.1:8080/v1?q="bad"' }
    ) {
        $r = Run-Url -Url $Url
        $r.ExitCode | Should -Not -Be 0
        Should-ContainText $r.Output 'invalid'
    }

    It 'allows non-loopback with -AllowNonlocalLlm' {
        (Run-Url -Url 'http://192.168.1.1:8080/v1' -Extra @('-AllowNonlocalLlm')).ExitCode | Should -Be 0
    }

    It 'derives the completions URL preserving the query' {
        $r = Run-Url -Url 'http://127.0.0.1:8080/v1?api_version=2024'
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output 'LLM completions: http://127.0.0.1:8080/v1/completions?api_version=2024'
    }

    It 'normalizes a trailing slash before deriving completions' -ForEach @(
        @{ Url = 'http://127.0.0.1:8080/v1/'; Expected = 'http://127.0.0.1:8080/v1/completions' }
        @{ Url = 'http://127.0.0.1:8080/v1/?api_version=2024'; Expected = 'http://127.0.0.1:8080/v1/completions?api_version=2024' }
    ) {
        $r = Run-Url -Url $Url
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output "LLM completions: $Expected"
        Should-NotContainText $r.Output '/v1//completions'
    }
}
