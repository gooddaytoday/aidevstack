# Zed Secure Install

Privacy-first installer for [Zed](https://zed.dev/) on Linux. Configures Zed for working with proprietary code using a local OpenAI-compatible LLM, with telemetry and cloud AI disabled by default.

## Threat Model

| Layer | What it protects | Limitation |
|-------|------------------|------------|
| **settings.json** | Telemetry, crash reports, update checks, sign-in UI, cloud tool permissions | Does not block network at OS level |
| **zed-secure wrapper** | Clears documented built-in provider API keys from the environment | Keys in the OS keychain and custom `<PROVIDER_ID>_API_KEY` variables still require manual removal |
| **Network sandbox** | Blocks direct non-loopback IPv4/IPv6 traffic from the Zed service cgroup via a verified transient system service (enabled by default for local-AI) | Requires `sudo`, Python 3, systemd cgroup-BPF support, and an administrator prompt on each launch; local IPC/brokers remain reachable |
| **Endpoint blocklist** (`--enable-endpoint-blocklist`) | Best-effort `/etc/hosts` for known cloud domains (no global nft rules) | Not authoritative; hostname-only; does not block all egress OS-wide; wildcards unsupported in hosts |

**For proprietary code with local AI:** network sandbox is requested automatically when you pass `--llm-model`. Installation and every protected launch verify real filtering in a root-managed transient service; failure stops Zed. Use `--no-network-sandbox` only if you accept cloud egress risk. Settings alone are not sufficient.

## Requirements

- Linux x86_64 or aarch64 with glibc ≥ 2.31 (x86_64) / ≥ 2.35 (aarch64)
- `curl` or `wget`
- Vulkan-capable GPU (see [Zed Linux docs](https://zed.dev/docs/linux))
- Local OpenAI-compatible LLM server (llama.cpp, vLLM, LM Studio, etc.) — **not installed by this script**
- `jq` — required when updating an existing `settings.json`, `--repair-settings`, `--merge-config`, or `--refresh-llm-config` (fresh install with no settings file does not need `jq`)
- `python3` — required for the network-sandbox probe; also used to normalize JSONC before settings overlay
- systemd with working system-manager cgroup-BPF IP filtering, plus `sudo` — required when the network sandbox is enabled

Run the installer as your ordinary desktop user, **not** with `sudo`; the
wrapper elevates only the `systemd-run` request and always runs Zed as the
original non-root UID/GID.

## Quick Start

Two preset installers wrap [`install-zed-secure.sh`](scripts/install-zed-secure.sh) with common flag combinations. Extra flags (`--dry-run`, `--channel`, `--offline`, etc.) are forwarded and can override non-AI preset behavior (for example `--no-network-sandbox` on the local-LLM preset).

### No AI (maximum privacy, no local LLM)

```sh
./scripts/install-zed-no-ai.sh
```

Always passes `--disable-ai` first; AI stays disabled even if you forward `--llm-model`.

### Local LLM with network sandbox (recommended)

```sh
./scripts/install-zed-local-llm.sh your-model-name
```

**MODEL must be the first argument** (not `--dry-run`). Example: `./scripts/install-zed-local-llm.sh my-model --dry-run`.

Preset includes: `--install-deps` (may run `sudo` on every install), loopback LLM URL, endpoint blocklist, and network sandbox (enabled automatically by the main installer). The sandbox also authenticates through `sudo` on every protected launch. To reconfigure without installing packages, use [`install-zed-secure.sh`](scripts/install-zed-secure.sh) without `--install-deps`.

### Dry run (preview actions)

```sh
./scripts/install-zed-no-ai.sh --dry-run
./scripts/install-zed-local-llm.sh test-model --dry-run
```

### Advanced: full installer

Use [`install-zed-secure.sh`](scripts/install-zed-secure.sh) when you need custom flags (see [Options](#options)):

```sh
./scripts/install-zed-secure.sh --disable-ai
./scripts/install-zed-secure.sh \
  --install-deps \
  --llm-model your-model-name \
  --llm-api-url 'http://127.0.0.1:8080/v1?api_version=2024' \
  --enable-endpoint-blocklist
./scripts/install-zed-secure.sh --channel preview --disable-ai --dry-run
```

## Options

| Flag | Description |
|------|-------------|
| `--install-deps` | Install system packages via apt/dnf/pacman/zypper |
| `--disable-ai` | Set `disable_ai: true`, disable all AI |
| `--llm-model MODEL` | Local model name (required unless `--disable-ai`) |
| `--llm-api-url URL` | Default: `http://127.0.0.1:8080/v1`. Supports path and query params (e.g. `?api_version=2024`, percent-encoding) and IPv6 loopback `http://[::1]:8080/v1` |
| `--llm-completions-url URL` | Edit predictions endpoint (default: `{api-url}/completions`) |
| `--disable-local-edit-predictions` | Disable inline completions, keep Agent Panel |
| `--allow-nonlocal-llm` | Allow LLM URL not on loopback (not recommended) |
| `--enable-network-sandbox` | Explicitly require a verified root-managed transient service with direct IP traffic limited to loopback (default for local-AI) |
| `--no-network-sandbox` | Opt out of network sandbox (not recommended for proprietary code) |
| `--allow-no-sandbox` | Allow installation to continue with the sandbox disabled if privileged verification fails |
| `--enable-endpoint-blocklist` | Add `/etc/hosts` blocklist for cloud endpoints (hosts only) |
| `--disable-endpoint-blocklist` | Remove `/etc/hosts` blocklist markers only (no settings/wrapper changes unless other install flags are passed) |
| `--do-not-hide-env-files` | Keep `.env` visible in file tree (still protected from AI writes) |
| `--merge-config` | Full merge via `jq`: security keys + `language_models` from template (requires `jq`) |
| `--refresh-llm-config` | Security overlay + overwrite `language_models` from template |
| `--repair-settings` | Re-apply privacy overlay only; no Zed/binary changes |
| `--regenerate-template` | With `--repair-settings`: overwrite template from current CLI flags (can change AI mode; use with care) |
| `--offline` | Fail if a network fetch would be required; use with `ZED_BUNDLE_PATH` in air-gapped environments |
| `--replace-zed-cli` | Replace `~/.local/bin/zed` with a symlink to `zed-secure` (opt-in; backs up existing `zed`) |
| `--dry-run` | Print actions without executing |
| `--uninstall` | Remove wrapper, desktop patches, blocklist |
| `--channel CHANNEL` | Release channel: `stable`, `preview`, `nightly`, or `dev` (default: `stable`) |
| `--version VERSION` | Zed version to install (default: `latest`) |

## Dangerous options

These flags weaken privacy guarantees or affect **all processes** under your user — use only with explicit intent:

| Flag | Risk | Mitigation |
|------|------|------------|
| `--allow-nonlocal-llm` | LLM traffic can leave loopback | Keep default loopback URLs; use network sandbox |
| `--uid-wide-strict-firewall` + `--i-accept-uid-wide-firewall` | **Blocks all outbound IPv4 and IPv6 except loopback** for your UID via nft (browsers, git, SSH, etc.) | Requires both flags; 5-second pause unless `--yes`; remove with `sudo nft delete table inet zed_uid_strict` or `--uninstall` |
| `--no-network-sandbox` | Zed may reach cloud endpoints | Default for local-AI installs is sandbox on |

## Release channels

The installer passes `ZED_CHANNEL` to the official Zed install script. App bundle and desktop entry paths depend on the channel:

| Channel | App directory | Desktop entry |
|---------|---------------|---------------|
| `stable` | `~/.local/zed.app` | `dev.zed.Zed.desktop` |
| `preview` | `~/.local/zed-preview.app` | `dev.zed.Zed-Preview.desktop` |
| `nightly` | `~/.local/zed-nightly.app` | `dev.zed.Zed-Nightly.desktop` |
| `dev` | `~/.local/zed-dev.app` | `dev.zed.Zed-Dev.desktop` |

`zed-secure` and the patched desktop entry always point at the binary for the channel you installed. Settings remain in `~/.config/zed/settings.json` (shared across channels, same as upstream Zed).

For a network install, this project downloads `https://zed.dev/install.sh` completely before executing it; it never streams a partial response into a shell. Set `ZED_INSTALLER_SHA256` to a trusted 64-character digest to require verification. Without it, the installer prints a warning because HTTPS alone does not pin the upstream script. For stronger provenance, download a release asset and its published SHA-256 separately, verify it, and use the offline flow below.

## What Gets Configured

Written to `~/.config/zed/settings.json` on each install run. A security template is also saved as `~/.config/zed/settings.zed-secure-template.json`.

| Situation | Behavior |
|-----------|----------|
| No existing `settings.json` | Full secure template written |
| Existing file (default) | **Security-only overlay** — privacy keys from template; your `language_models`, themes, editor keys preserved |
| `--merge-config` | Full merge including `language_models` from template |
| `--refresh-llm-config` | Security overlay + overwrite `language_models` from template |
| `--repair-settings` | Re-apply security overlay only (no Zed reinstall); close Zed first |

Timestamped backups: `settings.json.bak.<YYYYMMDDHHMMSS>` before each write.

### Telemetry and Zed UI

The installer sets `telemetry.diagnostics` and `telemetry.metrics` to `false`. **Zed can turn them back on** when you save settings from the UI (Settings → telemetry).

Defense in depth:

1. **`zed-secure` on each launch** re-applies the privacy overlay from `settings.zed-secure-template.json` (disable with `ZED_SECURE_ENFORCE_SETTINGS=0`).
2. **`--repair-settings`** fixes `settings.json` without reinstalling Zed (close Zed first). If the template file is missing, the installer infers AI mode from your current `settings.json` instead of guessing from CLI flags.
3. Close Zed before running the installer to avoid a race with the UI overwriting the file.

**Sed fallback (partial fix):** If `settings.json` cannot be parsed as JSON (common after Zed UI saves JSONC), enforcement may apply a **sed-only** fix for `telemetry` and `auto_update` only. It does **not** update `disable_ai`, `agent`, or `title_bar` — install `jq` + `python3` and run `--repair-settings` for a full overlay.

```sh
./scripts/install-zed-secure.sh --repair-settings
ZED_SECURE_ENFORCE_SETTINGS=0 zed-secure .   # opt out of launch-time enforce
ZED_SECURE_ENFORCE_STRICT=1 zed-secure .     # abort launch if overlay fails (exit 1)
```

Privacy and AI defaults applied by the template:

- `telemetry.diagnostics: false` — no crash reports
- `telemetry.metrics: false` — no usage metrics
- `auto_update: false` — no update checks
- `show_sign_in: false` — hide sign-in button
- Local OpenAI-compatible provider on loopback only
- Agent tools: `fetch` and `search_web` denied; sensitive file paths blocked (written even with `--disable-ai` for defense-in-depth)
- Optional: `.env` and secrets excluded from file tree

## Launch

After install, use the secure wrapper:

```sh
zed-secure /path/to/project
```

Or open Zed from the application menu (desktop entry is patched automatically).

For a sandboxed launch, `zed-secure` requests administrator authentication,
starts Zed as your original UID/GID in a transient **system** service, and tests
both working loopback and denied non-loopback traffic before executing Zed. A
missing helper/backend, cancelled prompt, unsupported BPF filter, or failed
probe is fatal; the wrapper never falls back to an ordinary launch. A desktop
launch without a terminal requires `SUDO_ASKPASS` to name an absolute,
executable helper whose file and parent chain are owned by root or your user
and not group/world writable; the wrapper invokes `sudo -A`. Otherwise, launch
from a terminal.

The protected instance uses a separate data directory under
`~/.local/share/zed-secure/<channel>` (extensions, databases, logs, and its IPC
socket) so it cannot forward into an ordinary Zed instance. Settings continue
to come from the normal `XDG_CONFIG_HOME`/`~/.config` location.

Optional: pass `--replace-zed-cli` during install to make `zed` in `~/.local/bin` point at `zed-secure` as well. The upstream app binary (for example `~/.local/zed.app/bin/zed`) can still be launched directly and **bypasses** env key clearing and network sandbox — do not use it for secure workflows.

## Environment Variables

```sh
export ZED_LLM_MODEL=my-model
export ZED_LLM_API_URL=http://127.0.0.1:8080/v1
export ZED_CHANNEL=stable   # stable | preview | nightly | dev
export ZED_VERSION=latest
export ZED_INSTALLER_SHA256=YOUR_TRUSTED_64_CHARACTER_SHA256  # optional network-script pin
export ZED_BUNDLE_PATH=/path/to/zed-linux-x86_64.tar.gz  # local tarball for offline install
```

## Offline / air-gapped install

For machines without access to `zed.dev`, download the official Linux tarball on a connected host, transfer it, then install locally:

```sh
export ZED_BUNDLE_PATH=/path/to/zed-linux-x86_64.tar.gz
./scripts/install-zed-secure.sh --disable-ai --offline
```

With `ZED_BUNDLE_PATH` set, the installer extracts the tarball into a staging directory, validates the expected executable, and only then replaces the live app directory (no `curl` to the upstream install script). A corrupt or wrong-layout bundle leaves the prior app directory intact. `--offline` makes network fetch a hard error when a local bundle or existing installation is unavailable.

Verify the bundle against the SHA-256 published with the corresponding Zed release before running this installer; `ZED_BUNDLE_PATH` itself does not assert artifact provenance.

Supported bundle names follow upstream: `zed-linux-x86_64.tar.gz` or `zed-linux-aarch64.tar.gz`. Channel-specific app directories (`zed.app`, `zed-preview.app`, etc.) are handled automatically via `--channel`.

## Verification

```sh
make test          # or: ./tests/run.sh
sh -n scripts/install-zed-secure.sh
shellcheck -s sh scripts/install-zed-secure.sh   # if installed
ZED_SANDBOX_PRIVILEGED_TEST=1 sh tests/test_network_sandbox_privileged.sh  # live PID 1/BPF probe; prompts for sudo
grep -E 'telemetry|auto_update|show_sign_in' ~/.config/zed/settings.json
zed-secure --version
curl http://127.0.0.1:8080/v1/models              # if LLM server running
```

In Zed: Command Palette → `zed: open telemetry log` — should stay empty after use.

## Uninstall

```sh
./scripts/install-zed-secure.sh --uninstall
~/.local/bin/zed --uninstall   # removes Zed itself
```

## Known Limitations

1. **No `disable_cloud_ai` setting** — Zed has no setting to disable cloud providers while keeping local AI. Mitigation: loopback-only URLs + network sandbox (on by default for local-AI) + no sign-in.
2. **Training data opt-in** — UI toggle only; no settings key.
3. **Server-side telemetry** — Cannot be disabled when using sign-in, hosted AI, or collaboration.
4. **Extensions** — Direct non-loopback IP traffic from Zed and its children is blocked, but avoid untrusted extensions.
5. **Endpoint blocklist** — Hosts-only best-effort; no global nft drop rules; does not replace process-level sandbox (enabled by default for local-AI installs).
6. **NixOS/Alpine** — Official binary may need glibc compatibility layer.
7. **Sandbox boundary** — The cgroup filter does not isolate files, Unix sockets, session D-Bus, inherited descriptors, the display server, or services reachable over localhost. Those channels can broker network access; this is direct IP-egress control, not a complete hostile-code sandbox.

## Windows 11+

A Windows port lives in [`scripts/windows/`](scripts/windows/) (PowerShell 5.1, no extra
prerequisites). It mirrors this tool's flags, privacy overlay, dry-run discipline, and
launch-time enforcement, substituting Windows-native facilities:

- **Network sandbox** → a persistent per-application **Windows Defender Firewall** outbound-block
  rule on `Zed.exe` (loopback stays reachable), enabled by default for local-AI installs; plus an
  opt-in machine-wide strict tier. (Linux uses a verified, authenticated transient system service.)
- **Endpoint blocklist** → the same marker block in `%SystemRoot%\System32\drivers\etc\hosts`.
- **Launcher** → clears cloud API key env vars + re-applies the overlay, behind a no-flash shortcut.
- **Settings** → `%APPDATA%\Zed\settings.json`, same overlay/merge/repair semantics.

```powershell
.\scripts\windows\Install-ZedNoAi.ps1                 # maximum privacy, no LLM
.\scripts\windows\Install-ZedLocalLlm.ps1 your-model  # local LLM + firewall sandbox
.\scripts\windows\Install-ZedLocalLlm.ps1 m -DryRun   # preview, no changes
```

See [docs/zed-secure-install-windows.md](docs/zed-secure-install-windows.md) for the full Windows
guide and [docs/zed-secure-install-windows-parity.md](docs/zed-secure-install-windows-parity.md) for
the R1–R14 parity map and the Windows-specific gaps (notably: the per-app firewall blocks `Zed.exe`
but not its child processes).

## References

- [Zed Linux install](https://zed.dev/docs/linux)
- [Telemetry settings](https://zed.dev/docs/telemetry)
- [AI configuration](https://zed.dev/docs/ai/configuration)
- [Local edit prediction](https://zed.dev/docs/ai/edit-prediction)
- [Tool permissions](https://zed.dev/docs/ai/tool-permissions)
