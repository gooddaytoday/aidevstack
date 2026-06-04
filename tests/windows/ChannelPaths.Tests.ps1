# Mirrors test_channel_paths.sh (channel-specific Windows app dir)
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe 'Channel-specific app paths' {
    It 'maps channels to Windows app directories' -ForEach @(
        @{ Channel = 'stable';  Dir = '\Programs\Zed\Zed.exe' }
        @{ Channel = 'preview'; Dir = 'Zed Preview' }
        @{ Channel = 'nightly'; Dir = 'Zed Nightly' }
        @{ Channel = 'dev';     Dir = 'Zed Dev' }
    ) {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-Channel', $Channel, '-DisableAi', '-DryRun')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output "Channel:    $Channel"
        Should-ContainText $r.Output $Dir
    }

    It 'honors ZED_CHANNEL from the environment' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-DryRun') -EnvVars @{ ZED_CHANNEL = 'preview' }
        Should-ContainText $r.Output 'Channel:    preview'
    }

    It 'rejects an unknown channel' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-Channel', 'bogus', '-DisableAi', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
    }
}
