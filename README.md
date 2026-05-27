# Zed Secure Install

Privacy-first installer for [Zed](https://zed.dev/) on Linux. Configures Zed for working with proprietary code using a local OpenAI-compatible LLM, with telemetry and cloud AI disabled by default.

## Threat Model

| Layer | What it protects | Limitation |
|-------|------------------|------------|
| **settings.json** | Telemetry, crash reports, update checks, sign-in UI, cloud tool permissions | Does not block network at OS level |
| **zed-secure wrapper** | Clears cloud API keys from environment | Keys in OS keychain still possible if added manually |
| **Network sandbox** | Blocks all outbound except loopback via `systemd-run` (enabled by default for local-AI) | Requires systemd; breaks extension marketplace, remote LSP |
| **Endpoint blocklist** (`--enable-endpoint-blocklist`) | Best-effort `/etc/hosts` for known cloud domains (no global nft rules) | Not authoritative; hostname-only; does not block all egress OS-wide; wildcards unsupported in hosts |

**For proprietary code with local AI:** network sandbox is enabled automatically when you pass `--llm-model`. Use `--no-network-sandbox` only if you accept cloud egress risk. Settings alone are not sufficient.

## Requirements

- Linux x86_64 or aarch64 with glibc ≥ 2.31 (x86_64) / ≥ 2.35 (aarch64)
- `curl` or `wget`
- Vulkan-capable GPU (see [Zed Linux docs](https://zed.dev/docs/linux))
- Local OpenAI-compatible LLM server (llama.cpp, vLLM, LM Studio, etc.) — **not installed by this script**

## Quick Start

### No AI (maximum privacy, no local LLM)

```sh
./scripts/install-zed-secure.sh --disable-ai
```

### Local LLM with network sandbox (recommended)

```sh
./scripts/install-zed-secure.sh \
  --install-deps \
  --llm-model your-model-name \
  --llm-api-url http://127.0.0.1:8080/v1 \
  --enable-endpoint-blocklist
```

### Dry run (preview actions)

```sh
./scripts/install-zed-secure.sh \
  --llm-model test-model \
  --dry-run
```

### Preview channel (dry run)

```sh
./scripts/install-zed-secure.sh --channel preview --disable-ai --dry-run
```

## Options

| Flag | Description |
|------|-------------|
| `--install-deps` | Install system packages via apt/dnf/pacman/zypper |
| `--disable-ai` | Set `disable_ai: true`, disable all AI |
| `--llm-model MODEL` | Local model name (required unless `--disable-ai`) |
| `--llm-api-url URL` | Default: `http://127.0.0.1:8080/v1` (also accepts `http://[::1]:8080/v1`) |
| `--llm-completions-url URL` | Edit predictions endpoint (default: `{api-url}/completions`) |
| `--disable-local-edit-predictions` | Disable inline completions, keep Agent Panel |
| `--allow-nonlocal-llm` | Allow LLM URL not on loopback (not recommended) |
| `--enable-network-sandbox` | Explicitly enable `systemd-run` localhost-only network (default for local-AI) |
| `--no-network-sandbox` | Opt out of network sandbox (not recommended for proprietary code) |
| `--allow-no-sandbox` | Continue if sandbox unavailable (local-AI default expects sandbox) |
| `--enable-endpoint-blocklist` | Add `/etc/hosts` blocklist for cloud endpoints (hosts only) |
| `--do-not-hide-env-files` | Keep `.env` visible in file tree (still protected from AI writes) |
| `--force-config` | Overwrite existing settings (with backup) |
| `--merge-config` | Merge with existing settings via `jq` |
| `--dry-run` | Print actions without executing |
| `--uninstall` | Remove wrapper, desktop patches, blocklist |
| `--channel CHANNEL` | Release channel: `stable`, `preview`, `nightly`, or `dev` (default: `stable`) |
| `--version VERSION` | Zed version to install (default: `latest`) |

## Release channels

The installer passes `ZED_CHANNEL` to the official Zed install script. App bundle and desktop entry paths depend on the channel:

| Channel | App directory | Desktop entry |
|---------|---------------|---------------|
| `stable` | `~/.local/zed.app` | `dev.zed.Zed.desktop` |
| `preview` | `~/.local/zed-preview.app` | `dev.zed.Zed-Preview.desktop` |
| `nightly` | `~/.local/zed-nightly.app` | `dev.zed.Zed-Nightly.desktop` |
| `dev` | `~/.local/zed-dev.app` | `dev.zed.Zed-Dev.desktop` |

`zed-secure` and the patched desktop entry always point at the binary for the channel you installed. Settings remain in `~/.config/zed/settings.json` (shared across channels, same as upstream Zed).

## What Gets Configured

Written to `~/.config/zed/settings.json` **before first launch**:

- `telemetry.diagnostics: false` — no crash reports
- `telemetry.metrics: false` — no usage metrics
- `auto_update: false` — no update checks
- `show_sign_in: false` — hide sign-in button
- Local OpenAI-compatible provider on loopback only
- Agent tools: `fetch` and `search_web` denied; sensitive file paths blocked
- Optional: `.env` and secrets excluded from file tree

## Launch

After install, always use the secure wrapper:

```sh
zed-secure /path/to/project
```

Or open Zed from the application menu (desktop entry is patched automatically).

## Environment Variables

```sh
export ZED_LLM_MODEL=my-model
export ZED_LLM_API_URL=http://127.0.0.1:8080/v1
export ZED_CHANNEL=stable   # stable | preview | nightly | dev
export ZED_VERSION=latest
export ZED_BUNDLE_PATH=/path/to/zed-linux-x86_64.tar.gz  # offline install
```

## Verification

```sh
sh -n scripts/install-zed-secure.sh
shellcheck -s sh scripts/install-zed-secure.sh   # if installed
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
4. **Extensions** — May make network requests; avoid untrusted extensions.
5. **Endpoint blocklist** — Hosts-only best-effort; no global nft drop rules; does not replace process-level sandbox (enabled by default for local-AI installs).
6. **NixOS/Alpine** — Official binary may need glibc compatibility layer.

## References

- [Zed Linux install](https://zed.dev/docs/linux)
- [Telemetry settings](https://zed.dev/docs/telemetry)
- [AI configuration](https://zed.dev/docs/ai/configuration)
- [Local edit prediction](https://zed.dev/docs/ai/edit-prediction)
- [Tool permissions](https://zed.dev/docs/ai/tool-permissions)
