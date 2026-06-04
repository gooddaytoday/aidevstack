# Windows port parity (W1–W14) and gaps

How the Windows port ([`../scripts/windows/`](../scripts/windows/)) maps to the Linux tool's
requirements R1–R14 (see [zed-secure-install-improvements.md](zed-secure-install-improvements.md)),
plus the Windows-specific gaps and out-of-scope items. User docs:
[zed-secure-install-windows.md](zed-secure-install-windows.md).

## Requirement parity

| ID | Linux requirement | Windows behavior | Parity |
|----|-------------------|------------------|--------|
| **W1** | R1: no machine-wide drop by default (endpoint blocklist is hosts-only) | Endpoint blocklist is hosts-only; the per-app firewall rule is scoped to `Zed.exe`, not machine-wide. Machine-wide blocking is opt-in only (`-MachineWideStrictFirewall`). | Full |
| **W2** | R2: channel-specific app paths | `Get-ZedChannelDirName` maps `stable/preview/nightly/dev` to `%LOCALAPPDATA%\Programs\Zed[ Preview/Nightly/Dev]`; `Resolve-ZedAppPath` also checks PATH and the registry Uninstall keys. | Full (path resolution multi-source) |
| **W3** | R3: network sandbox on by default for local-AI | `Set-LocalAiSandboxDefault` enables the per-app Windows Firewall rule when `-LlmModel` is set and not `-DisableAi`; `-NoNetworkSandbox` opts out with the same warning. | Full (mechanism differs: persistent firewall vs per-launch `systemd-run`) |
| **W4** | R4: IPv6 loopback URL validation | `Get-ZedUrlHost` / `Test-ZedLoopbackUrl` accept `127.0.0.1`, `localhost`, `[::1]`. | Full |
| **W5** | R5: URL validation with query/path | `Test-UrlValid` (char allowlist, `@` rejected, http/https only); `Get-ZedCompletionsUrl` preserves the query when deriving `/completions`. | Full |
| **W6** | R6: idempotent blocklist | `Invoke-ZedFirewallStep.ps1` uses the same begin/end markers; re-adding is a no-op. Firewall rules are idempotent by `-Group` (re-pointed, not duplicated). | Full |
| **W7** | R7: `--force-config` removed | No `-ForceConfig`; `[CmdletBinding()]` rejects it as an unknown parameter; backup-on-overwrite is always on. | Full |
| **W8** | R8: deep merge for `--merge-config` | `Merge-PSObjectDeep` + `Merge-ZedOverlay` reproduce the jq deep-merge-then-force-overwrite, dropping stale nested keys (`telemetry.extra_old`) while preserving user keys. | Full |
| **W9** | R9: offline install via bundle | `ZED_BUNDLE_PATH` (a `.zip`) expanded via `Expand-Archive`; `-Offline` errors without a bundle. | Full (zip instead of tar.gz) |
| **W10** | R10: launcher bypass protection / `-ReplaceZedCli` | Shortcuts repointed to the launcher; `-ReplaceZedCli` repoints the PATH `zed` shim (with backup/restore). | Full (shim instead of symlink; see gaps) |
| **W11** | R11: `-DisableEndpointBlocklist` without reinstall | Bare `-DisableEndpointBlocklist` removes the hosts block and exits; combined with an action flag (e.g. `-LlmModel`) it proceeds to install. Same `ActionRequested` logic. | Full |
| **W12** | R12: confirm for the dangerous firewall | `-MachineWideStrictFirewall` requires `-IAcceptMachineWideFirewall`, prints the danger warning, and pauses 5s unless `-Yes`. | Full |
| **W13** | R13: agent tool permissions always written | `New-ZedSettingsObject` always emits `agent.tool_permissions` (fetch/search_web denied) even with `-DisableAi`; merge overwrites permissive permissions. | Full |
| **W14** | R14: automated testing | Pester suite under [`../tests/windows/`](../tests/windows/) mirroring all 17 Linux test files; `Invoke-Tests.ps1` runner; `windows-latest` CI job (5.1 baseline + pwsh 7 leg); PSScriptAnalyzer as the ShellCheck analog. | Full |

## Windows-specific gaps (not present in the Linux tool)

1. **Per-app firewall is process-scoped.** The default sandbox blocks `Zed.exe` only. Linux's
   `systemd-run --scope` confines the whole cgroup including child processes (language servers,
   `node`, `git`, downloaded extension binaries). On Windows those run under different exe paths and
   are **not** blocked. Mitigations: the hosts blocklist (known domains) and `-MachineWideStrictFirewall`
   (full lockdown). Documented in the threat model and Known Limitations.
2. **Exe path changes on update.** The firewall rule is keyed to `Zed.exe`'s full path. A Zed
   self-update can move the exe, leaving the rule on a stale path. Mitigation: `auto_update: false`
   is enforced; update via `winget upgrade` then re-run the installer (re-points the rule).
3. **Shortcut / CLI revert on update.** A Zed update may overwrite the Start Menu shortcut and any
   `zed` shim, reverting them to the raw exe (bypassing env-clearing and launch-time enforcement).
   The persistent firewall rule still applies; re-run the installer after updates.
4. **PowerShell 5.1 JSON fidelity.** 5.1's `ConvertTo-Json` unwraps single-element arrays and writes
   a BOM. The module uses a custom serializer (`ConvertTo-ZedJson`) + BOM-less writer and a
   string-literal-aware JSONC normalizer to avoid corrupting URLs inside strings.
5. **Installer silent flags (TODO).** Acquisition is winget-first (silent by contract) + `.zip`
   bundle. Downloading and silently running the official `.exe` (Inno `/VERYSILENT` vs NSIS `/S`) is
   not implemented; the flags must be confirmed before adding that fallback.
6. **Code signing / SmartScreen.** Generated `.ps1`/`.vbs`/`.cmd` are unsigned; shims run with
   `-ExecutionPolicy Bypass`. Signing is recommended for managed distribution but out of scope here.

## Out of scope (same posture as Linux)

- Does **not** install or run the local LLM server.
- Does **not** clear cloud API keys from **Windows Credential Manager** (DPAPI) — only the process
  environment is cleared (parity with the Linux keychain caveat).
- Does **not** automate VM / Windows Sandbox / WSL2 isolation (a possible future route for true,
  child-inclusive confinement).
- Inherits trust in the upstream Zed installer (winget package / official build), as the Linux tool
  trusts `zed.dev/install.sh`.

## Verify during real-hardware testing

These are exercised by CI only at the dry-run / mocked level; confirm on a real Windows 11 box:

- Per-app firewall rule actually blocks `Zed.exe` egress while loopback to the local LLM works.
- The no-flash launcher shows no console window from a Start Menu launch and forwards args/cwd.
- UAC elevates only `Invoke-ZedFirewallStep.ps1` (never in `-DryRun`); unprivileged steps never prompt.
- A blocked domain resolves to `0.0.0.0` after `ipconfig /flushdns`.
- `Resolve-ZedAppPath` finds `Zed.exe` for each acquisition method (winget vs bundle).
