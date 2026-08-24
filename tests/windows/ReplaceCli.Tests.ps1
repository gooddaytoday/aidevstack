# Mirrors test_replace_zed_cli.sh (Windows: repoint the 'zed' shim, not a symlink)
BeforeAll { . (Join-Path $PSScriptRoot '_Common.ps1') }

Describe '-ReplaceZedCli' {
    It 'dry-run shows replace + backup actions' {
        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-ReplaceZedCli', '-DryRun')
        $r.ExitCode | Should -Be 0
        Should-ContainText $r.Output 'Would replace'
        Should-ContainText $r.Output 'Would backup existing'
    }

    It 'real install creates a zed shim pointing at the launcher' {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $envVars = New-ZedTestEnv -Root $root -SeedZed
        $envVars['USERPROFILE'] = (Join-Path $root 'profile')
        $envVars['ProgramData'] = (Join-Path $root 'programdata')
        New-Item -ItemType Directory -Force -Path $envVars['USERPROFILE'] | Out-Null
        New-Item -ItemType Directory -Force -Path $envVars['ProgramData'] | Out-Null

        $r = Invoke-ZedScript -Script 'Install-ZedSecure.ps1' -Arguments @('-DisableAi', '-ReplaceZedCli') -EnvVars $envVars
        $r.ExitCode | Should -Be 0
        $shim = Join-Path $envVars.LOCALAPPDATA 'zed-secure\bin\zed.cmd'
        (Test-Path -LiteralPath $shim) | Should -BeTrue
        (Get-Content -Raw -LiteralPath $shim) | Should -Match ([regex]::Escape('ZedSecureLauncher.ps1'))
    }
}
