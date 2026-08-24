# Mirrors test_channel_paths.sh (channel-specific Windows app dir)
BeforeAll {
    . (Join-Path $PSScriptRoot '_Common.ps1')
    . (Join-Path $ScriptsDir 'Install-ZedSecure.ps1')
}

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
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output 'Channel:    preview'
    }

    It 'rejects an unknown channel' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-Channel', 'bogus', '-DisableAi', '-DryRun')
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'Resolve-ZedAppPath channel isolation' {
    BeforeEach {
        $script:SavedPath = $env:Path
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $script:SavedProgramFiles = $env:ProgramFiles
        $script:ResolveRoot = Join-Path $TestDrive ([guid]::NewGuid())
        $script:FakeBin = Join-Path $script:ResolveRoot 'Zed'
        $env:LOCALAPPDATA = Join-Path $script:ResolveRoot 'local'
        $env:ProgramFiles = Join-Path $script:ResolveRoot 'program-files'
        New-Item -ItemType Directory -Force -Path $script:FakeBin, $env:LOCALAPPDATA, $env:ProgramFiles | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeBin 'zed.exe') -Value '' -NoNewline
        $env:Path = $script:FakeBin
        Mock Get-ChildItem { @() } -ParameterFilter { $Path -like 'HK*' }
    }

    AfterEach {
        $env:Path = $script:SavedPath
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:ProgramFiles = $script:SavedProgramFiles
    }

    It 'prefers the requested preview install over a stable PATH command' {
        $preview = Join-Path $env:LOCALAPPDATA 'Programs\Zed Preview\Zed.exe'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $preview) | Out-Null
        Set-Content -LiteralPath $preview -Value '' -NoNewline

        Resolve-ZedAppPath 'preview' | Should -Be $preview
    }

    It 'does not let a generic stable PATH command satisfy preview' {
        Resolve-ZedAppPath 'preview' | Should -BeNullOrEmpty
    }

    It 'does not let a preview PATH command satisfy stable' {
        $previewBin = Join-Path $script:ResolveRoot 'Zed Preview'
        New-Item -ItemType Directory -Force -Path $previewBin | Out-Null
        Set-Content -LiteralPath (Join-Path $previewBin 'zed.exe') -Value '' -NoNewline
        $env:Path = $previewBin

        Resolve-ZedAppPath 'stable' | Should -BeNullOrEmpty
    }
}
