# Shortcut patch/restore scope must stay symmetric across user and shared locations.
BeforeAll {
    . (Join-Path $PSScriptRoot '_Common.ps1')
    . (Join-Path $ScriptsDir 'Install-ZedSecure.ps1')
}

Describe 'Restore-Shortcuts scope' {
    BeforeEach {
        $script:SavedShortcutEnv = @{}
        foreach ($name in @('APPDATA', 'ProgramData', 'USERPROFILE', 'PUBLIC')) {
            $script:SavedShortcutEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, (Join-Path $TestDrive $name))
        }
        $script:DryRun = $false
    }

    AfterEach {
        foreach ($name in $script:SavedShortcutEnv.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedShortcutEnv[$name])
        }
    }

    It 'restores APPDATA, ProgramData, USERPROFILE, and PUBLIC shortcuts' {
        $candidates = @(Get-ZedShortcutCandidates)
        $candidates.Count | Should -Be 4

        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $lnk = $candidates[$i]
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lnk) | Out-Null
            Set-Content -LiteralPath "$lnk.bak.20260820$i" -Value "backup-$i" -NoNewline
        }

        Restore-Shortcuts

        for ($i = 0; $i -lt $candidates.Count; $i++) {
            (Get-Content -Raw -LiteralPath $candidates[$i]) | Should -Be "backup-$i"
        }
    }
}
