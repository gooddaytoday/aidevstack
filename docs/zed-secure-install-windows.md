# Zed Secure Install — Windows 11+

Privacy-first installer for [Zed](https://zed.dev/) on **Windows 11 and newer**. Configures Zed
for working with proprietary code using a local OpenAI-compatible LLM, with telemetry and cloud
AI disabled by default. This is the Windows port of the Linux tool in [`../scripts/`](../scripts/);
it reproduces the same flags, logging, dry-run discipline, and privacy overlay using
Windows-native facilities (Windows Defender Firewall, the hosts file, Start Menu shortcuts).

Scripts live in [`../scripts/windows/`](../scripts/windows/). See
[zed-secure-install-windows-parity.md](zed-secure-install-windows-parity.md) for a feature-by-feature
parity map and the Windows-specific gaps.

## Threat model

| Layer | What it protects | Limitation |
|-------|------------------|------------|
| **settings.json** | Telemetry, crash reports, update checks, sign-in UI, cloud tool permissions | Does not block network at OS level |
| **zed-secure launcher** | Clears cloud API keys from the environment before launching Zed | Keys in **Windows Credential Manager** (DPAPI) still possible if added manually |
| **Per-app firewall** (default for local-AI) | A persistent Windows Defender Firewall **outbound block rule on `Zed.exe`** — loopback (the local LLM) stays reachable | Blocks `Zed.exe` only, **not** child processes (language servers, `node`, `git`, extensions); requires admin once |
| **Machine-wide strict firewall** (`-MachineWideStrictFirewall`) | Blocks **all** outbound for the whole machine except loopback (closes the child-process gap) | Affects every program on the machine; dangerous; requires explicit consent |
| **Endpoint blocklist** (`-EnableEndpointBlocklist`) | Best-effort `hosts` entries for known cloud domains | Hostname-only; not authoritative; needs admin |

**For proprietary code with local AI:** the per-app firewall rule is created automatically when you
pass `-LlmModel`. Settings alone are not sufficient. Unlike the Linux per-launch sandbox, the
Windows rule is persistent and governs `Zed.exe` even when launched directly — but it does not
confine child processes. Use `-MachineWideStrictFirewall` if you need full egress lockdown.

## Requirements

- Windows 11 (build ≥ 22000) or newer
- Windows PowerShell 5.1 (preinstalled) — PowerShell 7 is used automatically if present
- A DirectX 11-capable GPU (verify with `dxdiag`)
- [winget](https://learn.microsoft.com/windows/package-manager/winget/) / "App Installer" (preinstalled on Win11) **or** a downloaded Zed `.zip` for offline install
- A local OpenAI-compatible LLM server (llama.cpp, vLLM, LM Studio, etc.) — **not installed by this script**
- Administrator rights are requested (UAC) **only** to create the firewall rule and edit the hosts file

## Quick start

Open a PowerShell prompt in `scripts\windows`. If scripts are blocked by execution policy, run them
with `powershell -ExecutionPolicy Bypass -File <script> ...`.

### No AI (maximum privacy, no local LLM)

```powershell
.\Install-ZedNoAi.ps1
```

Always passes `-DisableAi` first; AI stays disabled even if you forward `-LlmModel`.

### Local LLM with network sandbox (recommended)

```powershell
.\Install-ZedLocalLlm.ps1 your-model-name
```

**MODEL must be the first argument** (not `-DryRun`). The preset passes `-InstallDeps`, a loopback
LLM URL, `-EnableEndpointBlocklist`, and the per-app firewall sandbox (enabled by the main installer
when `-LlmModel` is set).

### Dry run (preview actions, no changes, no UAC)

```powershell
.\Install-ZedNoAi.ps1 -DryRun
.\Install-ZedLocalLlm.ps1 test-model -DryRun
```

### Advanced: full installer

```powershell
.\Install-ZedSecure.ps1 -DisableAi
.\Install-ZedSecure.ps1 -LlmModel your-model-name -LlmApiUrl 'http://127.0.0.1:8080/v1?api_version=2024' -EnableEndpointBlocklist
.\Install-ZedSecure.ps1 -Channel preview -DisableAi -DryRun
```

## Options

| Parameter | Description |
|-----------|-------------|
| `-InstallDeps` | Verify winget / App Installer is present (Windows has no system packages to install) |
| `-DisableAi` | Set `disable_ai: true`, disable all AI |
| `-LlmModel MODEL` | Local model name (required unless `-DisableAi`) |
| `-LlmApiUrl URL` | Default `http://127.0.0.1:8080/v1`; supports path and query params and IPv6 `http://[::1]:8080/v1` |
| `-LlmCompletionsUrl URL` | Edit-predictions endpoint (default `{api-url}/completions`) |
| `-DisableLocalEditPredictions` | Disable inline completions, keep the Agent Panel |
| `-AllowNonlocalLlm` | Allow an LLM URL not on loopback (not recommended) |
| `-EnableNetworkSandbox` | Explicitly create the per-app firewall rule (default for local-AI) |
| `-NoNetworkSandbox` | Opt out of the network sandbox (not recommended for proprietary code) |
| `-AllowNoSandbox` | Continue if Windows Firewall is unavailable |
| `-EnableEndpointBlocklist` | Add a `hosts` blocklist for cloud endpoints |
| `-DisableEndpointBlocklist` | Remove the `hosts` blocklist markers only |
| `-MachineWideStrictFirewall` | Block ALL machine outbound except loopback (dangerous; needs `-IAcceptMachineWideFirewall`) |
| `-IAcceptMachineWideFirewall` | Explicit consent for `-MachineWideStrictFirewall` |
| `-Yes` | Skip the 5-second confirmation pause for dangerous options |
| `-DoNotHideEnvFiles` | Keep `.env` visible in the file tree (still protected from AI writes) |
| `-MergeConfig` | Full merge: security keys + `language_models` from template |
| `-RefreshLlmConfig` | Security overlay + overwrite `language_models` from template |
| `-RepairSettings` | Re-apply the privacy overlay only; no Zed reinstall |
| `-RegenerateTemplate` | With `-RepairSettings`: overwrite the template from current parameters |
| `-Offline` | Fail if a network fetch would be required; use with `ZED_BUNDLE_PATH` |
| `-ReplaceZedCli` | Repoint the `zed` command on PATH to the secure launcher (opt-in) |
| `-Channel CHANNEL` | `stable`, `preview`, `nightly`, or `dev` (default `stable`; nightly/dev require a bundle) |
| `-ZedVersion VERSION` | Zed version (default `latest`) |
| `-DryRun` | Print actions without executing |
| `-Uninstall` | Remove launcher, firewall rule, shortcut patches, blocklist |
| `-Help` | Show usage |

## Paths

| What | Path |
|------|------|
| Settings | `%APPDATA%\Zed\settings.json` |
| Security template | `%APPDATA%\Zed\settings.zed-secure-template.json` |
| Launcher + enforce helper + template backup | `%LOCALAPPDATA%\zed-secure\` |
| `zed-secure` command (PATH) | `%LOCALAPPDATA%\zed-secure\bin\zed-secure.cmd` |
| Hosts file | `%SystemRoot%\System32\drivers\etc\hosts` |

## How settings are written

Same overlay model as Linux. On each install the secure template is generated and saved to both
`%APPDATA%\Zed` and `%LOCALAPPDATA%\zed-secure` (so enforcement survives config deletion).

| Situation | Behavior |
|-----------|----------|
| No existing `settings.json` | Full secure template written |
| Existing file (default) | **Security-only overlay** — privacy keys from template; your `language_models`, themes, editor keys preserved |
| `-MergeConfig` | Full merge including `language_models` from template |
| `-RefreshLlmConfig` | Security overlay + overwrite `language_models` |
| `-RepairSettings` | Re-apply security overlay only (no reinstall); close Zed first |

Timestamped backups (`settings.json.bak.<YYYYMMDDHHMMSS>`) are written before each change. Zed saves
settings as JSONC (with `//` comments and trailing commas); the overlay normalizes that before
merging. If the file cannot be parsed at all, a regex fallback fixes `telemetry` / `auto_update` /
`trust_all_worktrees` only — run `-RepairSettings` for a full overlay.

## Launch-time enforcement

The Zed UI can re-enable telemetry. The `zed-secure` launcher re-applies the privacy overlay on every
launch (disable with `ZED_SECURE_ENFORCE_SETTINGS=0`; abort on failure with `ZED_SECURE_ENFORCE_STRICT=1`).
Start Menu and Desktop shortcuts are repointed to the launcher (a no-flash `wscript`/`.vbs` entry, so no
console window appears). The launcher also clears cloud API key environment variables before starting Zed.

> A Zed self-update can recreate the shortcut and change `Zed.exe`'s path. The persistent firewall rule
> still governs `Zed.exe`, but re-run the installer after a Zed update to re-point the shortcut and the
> firewall rule, and to re-apply settings.

## Offline / air-gapped install

Download the Zed Windows `.zip` on a connected host, transfer it, then:

```powershell
$env:ZED_BUNDLE_PATH = 'C:\path\to\zed-windows-x86_64.zip'
.\Install-ZedSecure.ps1 -DisableAi -Offline
```

With `ZED_BUNDLE_PATH` set, the installer expands the archive (no winget). `-Offline` makes a network
fetch a hard error when no bundle and no existing install are available.

## Verification

```powershell
# Static: parse-check + Pester + PSScriptAnalyzer
.\..\..\tests\windows\Invoke-Tests.ps1

# After a real install:
Get-Content "$env:APPDATA\Zed\settings.json"        # telemetry/auto_update off, agent locked
Get-NetFirewallRule -Group zed-secure               # per-app egress rule bound to Zed.exe
zed-secure --version
```

Launch a local LLM on `127.0.0.1:8080`, open Zed via the Start Menu shortcut, and confirm the local
model works while the extension marketplace / cloud endpoints are unreachable (loopback succeeds).

## Uninstall

```powershell
.\Install-ZedSecure.ps1 -Uninstall
winget uninstall -e --id ZedIndustries.Zed   # removes Zed itself
```

## Known limitations

1. **Per-app firewall covers `Zed.exe` only** — child processes (LSPs, `node`, `git`, extension binaries)
   are not blocked. Use `-MachineWideStrictFirewall` for full egress lockdown, or rely on the hosts
   blocklist for known domains.
2. **Exe path changes on Zed update** can leave the firewall rule pointing at a stale path — keep
   `auto_update: false` (enforced) and re-run the installer after updates.
3. **Windows Credential Manager** — cloud API keys saved there are not cleared (parity with the Linux
   keychain caveat).
4. **Shortcut / CLI revert** — a Zed update may overwrite shortcuts; the persistent firewall rule still
   protects, but env-clearing/enforcement is skipped until you re-run the installer.
5. **Endpoint blocklist** — hosts-only, hostname-only, best-effort; does not replace the sandbox.
6. **Code signing / SmartScreen** — generated scripts are unsigned; the launcher shims use
   `-ExecutionPolicy Bypass`. Sign them for managed distribution.

## References

- [Zed on Windows](https://zed.dev/docs/windows)
- [Zed installation](https://zed.dev/docs/installation)
- [New-NetFirewallRule](https://learn.microsoft.com/powershell/module/netsecurity/new-netfirewallrule)
