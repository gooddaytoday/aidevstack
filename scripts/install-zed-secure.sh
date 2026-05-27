#!/bin/sh
# install-zed-secure.sh — Privacy-first Zed installer for Linux
# POSIX sh only. See README.md for usage and threat model.

set -eu

# --- Defaults (overridable via env) ---
INSTALL_DEPS=0
DISABLE_AI=0
DISABLE_LOCAL_EDIT_PREDICTIONS=0
ALLOW_NONLOCAL_LLM=0
ENABLE_NETWORK_SANDBOX=0
ENABLE_ENDPOINT_BLOCKLIST=0
DISABLE_ENDPOINT_BLOCKLIST=0
FORCE_CONFIG=0
MERGE_CONFIG=0
DO_NOT_HIDE_ENV_FILES=0
ALLOW_NO_SANDBOX=0
NO_NETWORK_SANDBOX=0
SANDBOX_EXPLICIT_ENABLE=0
UID_WIDE_STRICT_FIREWALL=0
DRY_RUN=0
UNINSTALL=0

ZED_CHANNEL="${ZED_CHANNEL:-stable}"
ZED_VERSION="${ZED_VERSION:-latest}"
ZED_LLM_MODEL="${ZED_LLM_MODEL:-}"
ZED_LLM_API_URL="${ZED_LLM_API_URL:-http://127.0.0.1:8080/v1}"
ZED_LLM_COMPLETIONS_URL="${ZED_LLM_COMPLETIONS_URL:-}"
ZED_LLM_PROVIDER_NAME="${ZED_LLM_PROVIDER_NAME:-LocalLLM}"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
ZED_CONFIG_DIR="$XDG_CONFIG_HOME/zed"
ZED_SETTINGS="$ZED_CONFIG_DIR/settings.json"
ZED_BIN_DIR="$HOME/.local/bin"
ZED_SECURE="$ZED_BIN_DIR/zed-secure"
ZED_APP_DIR=""
ZED_APP_BIN=""
ZED_DESKTOP_ID=""

HOSTS_MARKER_BEGIN="# zed-secure-blocklist begin"
HOSTS_MARKER_END="# zed-secure-blocklist end"

# Exact domains only (no wildcards in /etc/hosts)
BLOCKLIST_DOMAINS="
cloud.zed.dev
api2.amplitude.com
api.openai.com
api.anthropic.com
generativelanguage.googleapis.com
api.mistral.ai
api.x.ai
api.together.xyz
o4505698048008192.ingest.us.sentry.io
"

# --- Helpers ---

log() {
	printf '==> %s\n' "$*"
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '[dry-run] %s\n' "$*"
	else
		log "Running: $*"
		"$@"
	fi
}

usage() {
	cat <<'EOF'
Usage: install-zed-secure.sh [OPTIONS]

Privacy-first Zed installer for Linux with optional local OpenAI-compatible LLM.

Options:
  --install-deps              Install system dependencies (requires sudo)
  --disable-ai                Disable all AI features (disable_ai=true)
  --llm-model MODEL           Local model name (required unless --disable-ai)
  --llm-api-url URL           OpenAI-compatible API URL (default: http://127.0.0.1:8080/v1)
  --llm-completions-url URL   Completions endpoint for edit predictions
  --llm-provider-name NAME    Provider label in Zed UI (default: LocalLLM)
  --disable-local-edit-predictions
                              Disable inline edit predictions, keep Agent Panel
  --allow-nonlocal-llm        Allow LLM URL not on loopback (not recommended)
  --enable-network-sandbox    Run Zed via systemd-run with localhost-only network
                              (default for local-AI installs)
  --no-network-sandbox        Opt out of network sandbox (not recommended)
  --allow-no-sandbox          Continue if network sandbox is unavailable
  --enable-endpoint-blocklist Best-effort /etc/hosts only blocklist for cloud endpoints
  --disable-endpoint-blocklist
                              Remove endpoint blocklist markers
  --uid-wide-strict-firewall  Block all outbound traffic for current UID (dangerous)
  --do-not-hide-env-files     Do not exclude .env from file tree/search
  --force-config              Overwrite existing settings.json (with backup)
  --merge-config              Merge with existing settings.json via jq
  --channel CHANNEL           Zed release channel: stable|preview|nightly|dev (default: stable)
  --version VERSION           Zed version (default: latest)
  --dry-run                   Print actions without executing
  --uninstall                 Remove wrapper, desktop patches, blocklist markers
  -h, --help                  Show this help

Environment variables:
  ZED_CHANNEL, ZED_VERSION, ZED_BUNDLE_PATH
  ZED_LLM_MODEL, ZED_LLM_API_URL, ZED_LLM_COMPLETIONS_URL, ZED_LLM_PROVIDER_NAME
  XDG_CONFIG_HOME, XDG_DATA_HOME

Examples:
  ./install-zed-secure.sh --disable-ai
  ./install-zed-secure.sh --llm-model my-model --enable-endpoint-blocklist
  ./install-zed-secure.sh --install-deps --llm-model qwen2.5-coder \
    --enable-endpoint-blocklist --dry-run
  ./install-zed-secure.sh --llm-model my-model --no-network-sandbox
  ./install-zed-secure.sh --channel preview --disable-ai --dry-run

EOF
}

# --- CLI parser ---

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--install-deps) INSTALL_DEPS=1 ;;
		--disable-ai) DISABLE_AI=1 ;;
		--llm-model)
			shift
			[ "$#" -gt 0 ] || die "--llm-model requires an argument"
			ZED_LLM_MODEL=$1
			;;
		--llm-api-url)
			shift
			[ "$#" -gt 0 ] || die "--llm-api-url requires an argument"
			ZED_LLM_API_URL=$1
			;;
		--llm-completions-url)
			shift
			[ "$#" -gt 0 ] || die "--llm-completions-url requires an argument"
			ZED_LLM_COMPLETIONS_URL=$1
			;;
		--llm-provider-name)
			shift
			[ "$#" -gt 0 ] || die "--llm-provider-name requires an argument"
			ZED_LLM_PROVIDER_NAME=$1
			;;
		--disable-local-edit-predictions) DISABLE_LOCAL_EDIT_PREDICTIONS=1 ;;
		--allow-nonlocal-llm) ALLOW_NONLOCAL_LLM=1 ;;
		--enable-network-sandbox)
			ENABLE_NETWORK_SANDBOX=1
			SANDBOX_EXPLICIT_ENABLE=1
			;;
		--no-network-sandbox) NO_NETWORK_SANDBOX=1 ;;
		--allow-no-sandbox) ALLOW_NO_SANDBOX=1 ;;
		--enable-endpoint-blocklist) ENABLE_ENDPOINT_BLOCKLIST=1 ;;
		--disable-endpoint-blocklist) DISABLE_ENDPOINT_BLOCKLIST=1 ;;
		--uid-wide-strict-firewall) UID_WIDE_STRICT_FIREWALL=1 ;;
		--do-not-hide-env-files) DO_NOT_HIDE_ENV_FILES=1 ;;
		--force-config) FORCE_CONFIG=1 ;;
		--merge-config) MERGE_CONFIG=1 ;;
		--channel)
			shift
			[ "$#" -gt 0 ] || die "--channel requires an argument"
			ZED_CHANNEL=$1
			;;
		--version)
			shift
			[ "$#" -gt 0 ] || die "--version requires an argument"
			ZED_VERSION=$1
			;;
		--dry-run) DRY_RUN=1 ;;
		--uninstall) UNINSTALL=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			die "unknown option: $1 (use --help)"
			;;
		*)
			die "unexpected argument: $1 (use --help)"
			;;
		esac
		shift
	done
}

apply_local_ai_sandbox_defaults() {
	[ "$DISABLE_AI" -eq 0 ] && [ -n "$ZED_LLM_MODEL" ] || return 0

	if [ "$NO_NETWORK_SANDBOX" -eq 1 ] && [ "$SANDBOX_EXPLICIT_ENABLE" -eq 1 ]; then
		die "Cannot use --enable-network-sandbox and --no-network-sandbox together"
	fi

	if [ "$NO_NETWORK_SANDBOX" -eq 1 ]; then
		ENABLE_NETWORK_SANDBOX=0
		warn "Network sandbox DISABLED. Cloud egress remains possible for Zed processes."
		warn "This is NOT recommended when working with proprietary code."
		return 0
	fi

	if [ "$ENABLE_NETWORK_SANDBOX" -eq 0 ]; then
		ENABLE_NETWORK_SANDBOX=1
		log "Network sandbox enabled by default for local-AI install"
	fi
}

# --- Channel paths (mirror zed.dev/install.sh linux()) ---

validate_zed_channel() {
	case "$ZED_CHANNEL" in
	stable | preview | nightly | dev) ;;
	*)
		die "unknown --channel: $ZED_CHANNEL (allowed: stable, preview, nightly, dev)"
		;;
	esac
}

resolve_zed_app_paths() {
	suffix=""
	case "$ZED_CHANNEL" in
	stable) suffix="" ;;
	*) suffix="-$ZED_CHANNEL" ;;
	esac
	ZED_APP_DIR="$HOME/.local/zed${suffix}.app"
	case "$ZED_CHANNEL" in
	stable) ZED_DESKTOP_ID="dev.zed.Zed" ;;
	preview) ZED_DESKTOP_ID="dev.zed.Zed-Preview" ;;
	nightly) ZED_DESKTOP_ID="dev.zed.Zed-Nightly" ;;
	dev) ZED_DESKTOP_ID="dev.zed.Zed-Dev" ;;
	esac
	if [ -x "$ZED_APP_DIR/bin/zed" ]; then
		ZED_APP_BIN="$ZED_APP_DIR/bin/zed"
	elif [ -x "$ZED_APP_DIR/bin/cli" ]; then
		ZED_APP_BIN="$ZED_APP_DIR/bin/cli"
	else
		ZED_APP_BIN="$ZED_APP_DIR/bin/zed"
	fi
}

# --- Validation helpers ---

validate_model_name() {
	val=$1
	case "$val" in
	*\"* | *\\*)
		die "invalid characters in llm-model: quotes or backslashes not allowed"
		;;
	esac
	remainder=$(printf '%s' "$val" | tr -d 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
	if [ -n "$remainder" ]; then
		die "invalid characters in llm-model"
	fi
}

validate_provider_name() {
	val=$1
	case "$val" in
	*\"* | *\\*)
		die "invalid characters in llm-provider-name: quotes or backslashes not allowed"
		;;
	esac
	remainder=$(printf '%s' "$val" | tr -d 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-')
	if [ -n "$remainder" ]; then
		die "invalid characters in llm-provider-name"
	fi
}

validate_url() {
	val=$1
	name=$2
	case "$val" in
	*\"* | *\\*)
		die "invalid characters in $name: quotes or backslashes not allowed"
		;;
	http://* | https://*) ;;
	*)
		die "invalid $name: must start with http:// or https://"
		;;
	esac
	remainder=$(printf '%s' "$val" | tr -d 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/[]?&=%#-')
	if [ -n "$remainder" ]; then
		die "invalid characters in $name"
	fi
	case "$val" in
	http://*)
		rest=${val#http://}
		;;
	https://*)
		rest=${val#https://}
		;;
	esac
	authority=$rest
	case "$authority" in
	*/*)
		authority=${authority%%/*}
		;;
	esac
	case "$authority" in
	*\?*)
		authority=${authority%%\?*}
		;;
	esac
	case "$authority" in
	*#*)
		authority=${authority%%#*}
		;;
	esac
	case "$authority" in
	*@*)
		die "invalid characters in $name: userinfo (@) not allowed"
		;;
	esac
}

url_authority_host() {
	url=$1
	rest=""

	case "$url" in
	http://*)
		rest=${url#http://}
		;;
	https://*)
		rest=${url#https://}
		;;
	*)
		return 1
		;;
	esac

	authority=$rest
	case "$authority" in
	*/*)
		authority=${authority%%/*}
		;;
	esac
	case "$authority" in
	*\?*)
		authority=${authority%%\?*}
		;;
	esac
	case "$authority" in
	*#*)
		authority=${authority%%#*}
		;;
	esac
	case "$authority" in
	*@*)
		return 1
		;;
	esac

	case "$authority" in
	[[]*)
		host=${authority%%]*}
		host="${host}]"
		;;
	*:*)
		host=${authority%:*}
		;;
	*)
		host=$authority
		;;
	esac

	[ -n "$host" ] || return 1
	printf '%s\n' "$host"
}

is_loopback_host() {
	host=$1
	case "$host" in
	127.0.0.1 | localhost | [[]::1])
		return 0
		;;
	esac
	return 1
}

is_loopback_url() {
	url=$1
	host=$(url_authority_host "$url") || return 1
	is_loopback_host "$host"
}

derive_completions_url() {
	base=$1
	query=""
	path_base=$base

	case "$path_base" in
	*#*)
		path_base=${path_base%%#*}
		;;
	esac
	case "$path_base" in
	*\?*)
		query=${path_base#*\?}
		path_base=${path_base%%\?*}
		;;
	esac

	case "$path_base" in
	*/v1)
		completions="${path_base%/}/completions"
		;;
	*)
		completions="${path_base}/completions"
		;;
	esac

	if [ -n "$query" ]; then
		completions="${completions}?${query}"
	fi
	printf '%s\n' "$completions"
}

validate_llm_urls() {
	if [ "$DISABLE_AI" -eq 1 ]; then
		return 0
	fi

	[ -n "$ZED_LLM_MODEL" ] || die "--llm-model is required unless --disable-ai is set"

	validate_model_name "$ZED_LLM_MODEL"
	validate_provider_name "$ZED_LLM_PROVIDER_NAME"
	validate_url "$ZED_LLM_API_URL" "llm-api-url"

	if [ -z "$ZED_LLM_COMPLETIONS_URL" ]; then
		ZED_LLM_COMPLETIONS_URL=$(derive_completions_url "$ZED_LLM_API_URL")
	fi
	validate_url "$ZED_LLM_COMPLETIONS_URL" "llm-completions-url"

	if [ "$ALLOW_NONLOCAL_LLM" -eq 0 ]; then
		if ! is_loopback_url "$ZED_LLM_API_URL"; then
			die "LLM API URL must be loopback (127.0.0.1/localhost/::1). Use --allow-nonlocal-llm to override."
		fi
		if ! is_loopback_url "$ZED_LLM_COMPLETIONS_URL"; then
			die "LLM completions URL must be loopback. Use --allow-nonlocal-llm to override."
		fi
	else
		warn "Non-local LLM URL allowed. Proprietary code may leave your machine via the LLM server."
	fi
}

# --- Platform detection ---

detect_platform() {
	[ "$(uname -s)" = "Linux" ] || die "This script supports Linux only."

	ARCH=$(uname -m)
	case "$ARCH" in
	x86_64 | amd64) ARCH=x86_64 ;;
	aarch64 | arm64) ARCH=aarch64 ;;
	*)
		die "Unsupported architecture: $ARCH (supported: x86_64, aarch64)"
		;;
	esac

	OS_ID=""
	OS_ID_LIKE=""
	if [ -f /etc/os-release ]; then
		OS_ID=$(grep -E '^ID=' /etc/os-release | head -n1 | cut -d= -f2- | tr -d '"')
		OS_ID_LIKE=$(grep -E '^ID_LIKE=' /etc/os-release | head -n1 | cut -d= -f2- | tr -d '"')
	fi

	PKG_MGR=""
	case "$OS_ID" in
	debian | ubuntu | linuxmint | pop)
		PKG_MGR=apt
		;;
	fedora | rhel | centos | rocky | almalinux)
		PKG_MGR=dnf
		;;
	arch | manjaro)
		PKG_MGR=pacman
		;;
	opensuse* | sles)
		PKG_MGR=zypper
		;;
	nixos | alpine)
		warn "Distro $OS_ID may need a glibc compatibility layer for official Zed builds."
		warn "See: https://zed.dev/docs/linux"
		PKG_MGR=""
		;;
	*)
		case "$OS_ID_LIKE" in
		*debian* | *ubuntu*) PKG_MGR=apt ;;
		*fedora* | *rhel*) PKG_MGR=dnf ;;
		*arch*) PKG_MGR=pacman ;;
		*suse*) PKG_MGR=zypper ;;
		esac
		;;
	esac

	log "Detected: OS=$OS_ID ARCH=$ARCH PKG_MGR=${PKG_MGR:-unknown}"
}

check_glibc() {
	if ! have ldd; then
		warn "ldd not found; skipping glibc version check"
		return 0
	fi

	GLIBC_VER=$(ldd --version 2>&1 | head -n1 | sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
	[ -n "$GLIBC_VER" ] || warn "Could not parse glibc version"

	if [ -n "$GLIBC_VER" ]; then
		min_ver=2.31
		[ "$ARCH" = "aarch64" ] && min_ver=2.35

		# Compare major.minor numerically
		major=$(echo "$GLIBC_VER" | cut -d. -f1)
		minor=$(echo "$GLIBC_VER" | cut -d. -f2)
		min_major=$(echo "$min_ver" | cut -d. -f1)
		min_minor=$(echo "$min_ver" | cut -d. -f2)

		if [ "$major" -lt "$min_major" ] || { [ "$major" -eq "$min_major" ] && [ "$minor" -lt "$min_minor" ]; }; then
			die "glibc $GLIBC_VER is too old (need >= $min_ver for $ARCH). Build Zed from source: https://zed.dev/docs/development/linux"
		fi
		log "glibc version: $GLIBC_VER (OK)"
	fi
}

check_download_tool() {
	if have curl; then
		DOWNLOAD_CMD=curl
	elif have wget; then
		DOWNLOAD_CMD=wget
	else
		die "Need curl or wget to download Zed"
	fi
}

check_vulkan() {
	if have vulkaninfo || have vkcube; then
		return 0
	fi
	# Check common library paths
	for lib in libvulkan.so.1 libvulkan.so; do
		if have ldconfig && ldconfig -p 2>/dev/null | grep -q "$lib"; then
			return 0
		fi
	done
	warn "Vulkan not detected. Zed requires a Vulkan-capable GPU driver."
	warn "Install vulkan-tools and run: vkcube"
}

check_inotify() {
	if [ -r /proc/sys/fs/inotify/max_user_watches ]; then
		watches=$(cat /proc/sys/fs/inotify/max_user_watches)
		if [ "$watches" -lt 8000 ] 2>/dev/null; then
			warn "fs.inotify.max_user_watches=$watches (recommended >= 8000)"
			warn "Fix: sudo sysctl fs.inotify.max_user_watches=64000"
		fi
	fi
}

deps_list() {
	case "$PKG_MGR" in
	apt)
		echo "curl ca-certificates libvulkan1 vulkan-tools libsecret-1-0 gnome-keyring"
		;;
	dnf)
		echo "curl ca-certificates vulkan-loader vulkan-tools libsecret gnome-keyring"
		;;
	pacman)
		echo "curl ca-certificates vulkan-icd-loader vulkan-tools libsecret gnome-keyring"
		;;
	zypper)
		echo "curl ca-certificates libvulkan1 vulkan-tools libsecret-1-0 gnome-keyring"
		;;
	*)
		echo ""
		;;
	esac
}

check_deps() {
	missing=""
	for pkg in $(deps_list); do
		case "$PKG_MGR" in
		apt)
			if ! dpkg -s "$pkg" >/dev/null 2>&1; then
				missing="$missing $pkg"
			fi
			;;
		dnf)
			if ! rpm -q "$pkg" >/dev/null 2>&1; then
				missing="$missing $pkg"
			fi
			;;
		pacman)
			if ! pacman -Q "$pkg" >/dev/null 2>&1; then
				missing="$missing $pkg"
			fi
			;;
		zypper)
			if ! rpm -q "$pkg" >/dev/null 2>&1; then
				missing="$missing $pkg"
			fi
			;;
		esac
	done

	if [ -n "$missing" ]; then
		warn "Missing packages:$missing"
		case "$PKG_MGR" in
		apt) warn "Install: sudo apt install$missing" ;;
		dnf) warn "Install: sudo dnf install$missing" ;;
		pacman) warn "Install: sudo pacman -S$missing" ;;
		zypper) warn "Install: sudo zypper install$missing" ;;
		esac
		if [ "$INSTALL_DEPS" -eq 0 ]; then
			warn "Re-run with --install-deps to install automatically"
		fi
		return 1
	fi
	return 0
}

install_deps() {
	[ "$INSTALL_DEPS" -eq 1 ] || return 0
	[ -n "$PKG_MGR" ] || die "Cannot install deps: unknown package manager"

	pkgs=$(deps_list)
	case "$PKG_MGR" in
	apt)
		run sudo apt update
		# shellcheck disable=SC2086
		run sudo apt install -y $pkgs
		;;
	dnf)
		# shellcheck disable=SC2086
		run sudo dnf install -y $pkgs
		;;
	pacman)
		# shellcheck disable=SC2086
		run sudo pacman -S --needed --noconfirm $pkgs
		;;
	zypper)
		# shellcheck disable=SC2086
		run sudo zypper install -y $pkgs
		;;
	esac
}

# --- Zed installation ---

check_path() {
	case ":$PATH:" in
	*":$ZED_BIN_DIR:"*) ;;
	*)
		warn "$ZED_BIN_DIR is not in PATH"
		warn "Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
		;;
	esac
}

install_zed() {
	log "Installing Zed (channel=$ZED_CHANNEL version=$ZED_VERSION)"

	if [ -n "${ZED_BUNDLE_PATH:-}" ]; then
		run env ZED_CHANNEL="$ZED_CHANNEL" ZED_VERSION="$ZED_VERSION" ZED_BUNDLE_PATH="$ZED_BUNDLE_PATH" \
			sh -c 'curl -f https://zed.dev/install.sh | sh'
	else
		run env ZED_CHANNEL="$ZED_CHANNEL" ZED_VERSION="$ZED_VERSION" \
			sh -c 'curl -f https://zed.dev/install.sh | sh'
	fi

	if [ "$DRY_RUN" -eq 0 ] && [ ! -x "$ZED_APP_BIN" ]; then
		die "Zed binary not found under $ZED_APP_DIR after install (channel=$ZED_CHANNEL). Check upstream install output."
	fi

	run mkdir -p "$ZED_BIN_DIR"
	check_path
}

# --- Settings generation ---

file_scan_exclusions_json() {
	if [ "$DO_NOT_HIDE_ENV_FILES" -eq 1 ]; then
		cat <<'EOF'
  "file_scan_exclusions": [
    "**/.git", "**/.svn", "**/.hg", "**/CVS",
    "**/.DS_Store", "**/Thumbs.db", "**/.class",
    "**/*.pem", "**/*.key", "**/secrets/**", "**/credentials/**"
  ],
EOF
	else
		cat <<'EOF'
  "file_scan_exclusions": [
    "**/.git", "**/.svn", "**/.hg", "**/CVS",
    "**/.DS_Store", "**/Thumbs.db", "**/.class",
    "**/.env*", "**/*.pem", "**/*.key", "**/secrets/**", "**/credentials/**"
  ],
EOF
	fi
}

agent_tool_permissions_json() {
	cat <<'EOF'
  "agent": {
    "tool_permissions": {
      "default": "confirm",
      "tools": {
        "fetch": { "default": "deny" },
        "search_web": { "default": "deny" },
        "terminal": {
          "default": "confirm",
          "always_deny": [
            { "pattern": "api\\.openai\\.com|api\\.anthropic\\.com|generativelanguage\\.googleapis\\.com|cloud\\.zed\\.dev" }
          ]
        },
        "edit_file": {
          "default": "confirm",
          "always_deny": [
            { "pattern": "\\.env" },
            { "pattern": "secrets?/" },
            { "pattern": "\\.(pem|key|crt|p12)$" }
          ]
        },
        "write_file": {
          "default": "confirm",
          "always_deny": [
            { "pattern": "\\.env" },
            { "pattern": "secrets?/" },
            { "pattern": "\\.(pem|key|crt|p12)$" }
          ]
        },
        "delete_path": { "default": "confirm" }
      }
    }
  },
EOF
}

llm_config_json() {
	cat <<EOF
  "language_models": {
    "openai_compatible": {
      "$ZED_LLM_PROVIDER_NAME": {
        "api_url": "$ZED_LLM_API_URL",
        "available_models": [{
          "name": "$ZED_LLM_MODEL",
          "display_name": "Local LLM",
          "max_tokens": 32768,
          "capabilities": { "tools": true, "images": false }
        }]
      }
    }
  },
EOF
}

edit_predictions_json() {
	if [ "$DISABLE_LOCAL_EDIT_PREDICTIONS" -eq 1 ]; then
		cat <<'EOF'
  "show_edit_predictions": false,
  "edit_predictions": {
    "provider": "none"
  }
EOF
	else
		cat <<EOF
  "edit_predictions": {
    "provider": "open_ai_compatible_api",
    "open_ai_compatible_api": {
      "api_url": "$ZED_LLM_COMPLETIONS_URL",
      "model": "$ZED_LLM_MODEL",
      "prompt_format": "infer",
      "max_output_tokens": 512
    },
    "disabled_globs": ["**/.env*", "**/*.pem", "**/*.key", "**/secrets/**"]
  }
EOF
	fi
}

generate_settings_content() {
	disable_ai_val=false
	[ "$DISABLE_AI" -eq 1 ] && disable_ai_val=true

	cat <<EOF
{
  "auto_update": false,
  "disable_ai": $disable_ai_val,
  "telemetry": { "diagnostics": false, "metrics": false },
  "session": { "trust_all_worktrees": false },
  "title_bar": {
    "show_sign_in": false,
    "show_onboarding_banner": false,
    "show_user_picture": false,
    "show_user_menu": false
  },
  "collaboration_panel": { "button": false },
$(file_scan_exclusions_json)
EOF

	if [ "$DISABLE_AI" -eq 0 ]; then
		llm_config_json
		agent_tool_permissions_json
		edit_predictions_json
	else
		cat <<'EOF'
  "show_edit_predictions": false,
  "edit_predictions": { "provider": "none" }
EOF
	fi

	printf '%s\n' "}"
}

backup_settings() {
	if [ -f "$ZED_SETTINGS" ]; then
		ts=$(date +%Y%m%d%H%M%S)
		backup="$ZED_SETTINGS.bak.$ts"
		run cp "$ZED_SETTINGS" "$backup"
		log "Backed up existing settings to $backup"
	fi
}

write_settings() {
	run mkdir -p "$ZED_CONFIG_DIR"

	if [ -f "$ZED_SETTINGS" ] && [ "$MERGE_CONFIG" -eq 1 ]; then
		if ! have jq; then
			die "--merge-config requires jq"
		fi
		backup_settings
		tmp=$(mktemp)
		generate_settings_content >"$tmp"
		if [ "$DRY_RUN" -eq 0 ]; then
			jq -s 'add' "$ZED_SETTINGS" "$tmp" >"${ZED_SETTINGS}.new"
			mv "${ZED_SETTINGS}.new" "$ZED_SETTINGS"
		fi
		rm -f "$tmp"
	elif [ -f "$ZED_SETTINGS" ] && [ "$FORCE_CONFIG" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
		backup_settings
		generate_settings_content >"$ZED_SETTINGS"
	else
		if [ -f "$ZED_SETTINGS" ]; then
			backup_settings
		fi
		if [ "$DRY_RUN" -eq 1 ]; then
			log "Would write $ZED_SETTINGS"
		else
			generate_settings_content >"$ZED_SETTINGS"
		fi
	fi

	if [ "$DRY_RUN" -eq 0 ] && have jq && [ -f "$ZED_SETTINGS" ]; then
		if jq empty "$ZED_SETTINGS" 2>/dev/null; then
			log "settings.json validated with jq"
		else
			warn "settings.json failed jq validation"
		fi
	elif [ "$DRY_RUN" -eq 0 ] && ! have jq; then
		warn "jq not found; skipping JSON validation"
	fi
}

# --- Wrapper ---

systemd_run_supports_workdir() {
	if have systemd-run; then
		systemd-run --help 2>&1 | grep -q -- '--working-directory'
	else
		return 1
	fi
}

check_sandbox_available() {
	if [ "$ENABLE_NETWORK_SANDBOX" -eq 0 ]; then
		return 0
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would verify systemd-run network sandbox availability"
		return 0
	fi

	if ! have systemd-run; then
		if [ "$ALLOW_NO_SANDBOX" -eq 1 ]; then
			warn "systemd-run not found; continuing without network sandbox"
			ENABLE_NETWORK_SANDBOX=0
			return 0
		fi
		die "systemd-run not found. Install systemd or pass --allow-no-sandbox"
	fi

	# Test if IPAddressDeny is supported (quick dry test)
	if ! systemd-run --user --scope --quiet --collect \
		-p IPAddressDeny=any -p IPAddressAllow=localhost \
		true 2>/dev/null; then
		if [ "$ALLOW_NO_SANDBOX" -eq 1 ]; then
			warn "systemd IPAddressDeny not supported; continuing without sandbox"
			ENABLE_NETWORK_SANDBOX=0
			return 0
		fi
		die "systemd IPAddressDeny not supported. Pass --allow-no-sandbox to continue."
	fi

	log "Network sandbox available via systemd-run"
}

write_zed_secure_wrapper() {
	sandbox_default=0
	[ "$ENABLE_NETWORK_SANDBOX" -eq 1 ] && sandbox_default=1

	use_workdir=0
	if systemd_run_supports_workdir; then
		use_workdir=1
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would write $ZED_SECURE (binary: $ZED_APP_BIN)"
		return 0
	fi

	run mkdir -p "$ZED_BIN_DIR"

	{
		cat <<'WRAPPER_HEAD'
#!/bin/sh
set -eu

# Unset cloud API keys that Zed reads from environment
unset OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY XAI_API_KEY \
      GEMINI_API_KEY MISTRAL_API_KEY TOGETHER_AI_API_KEY VERCEL_AI_GATEWAY_API_KEY \
      OLLAMA_API_KEY VERCEL_AI_GATEWAY_API_KEY

ZED_BIN="${ZED_BIN:-WRAPPER_ZED_BIN_PLACEHOLDER}"
ZED_SECURE_NETWORK_SANDBOX="${ZED_SECURE_NETWORK_SANDBOX:-WRAPPER_SANDBOX_DEFAULT}"

if [ "$ZED_SECURE_NETWORK_SANDBOX" = "1" ] && command -v systemd-run >/dev/null 2>&1; then
WRAPPER_HEAD

		if [ "$use_workdir" -eq 1 ]; then
			cat <<'WRAPPER_WORKDIR'
  exec systemd-run --user --scope --quiet --collect \
    --working-directory="$(pwd -P)" \
    -p IPAddressDeny=any \
    -p IPAddressAllow=localhost \
    "$ZED_BIN" "$@"
WRAPPER_WORKDIR
		else
			cat <<'WRAPPER_NOWORKDIR'
  exec systemd-run --user --scope --quiet --collect \
    -p IPAddressDeny=any \
    -p IPAddressAllow=localhost \
    "$ZED_BIN" "$@"
WRAPPER_NOWORKDIR
		fi

		cat <<'WRAPPER_TAIL'
fi

exec "$ZED_BIN" "$@"
WRAPPER_TAIL
	} | sed "s|WRAPPER_ZED_BIN_PLACEHOLDER|$ZED_APP_BIN|g" \
		| sed "s|WRAPPER_SANDBOX_DEFAULT|$sandbox_default|g" \
		>"$ZED_SECURE"

	run chmod +x "$ZED_SECURE"
	log "Created wrapper: $ZED_SECURE"
}

patch_desktop_entry() {
	desktop=""
	for candidate in \
		"$XDG_DATA_HOME/applications/${ZED_DESKTOP_ID}.desktop" \
		"$HOME/.local/share/applications/${ZED_DESKTOP_ID}.desktop"; do
		if [ -f "$candidate" ]; then
			desktop=$candidate
			break
		fi
	done

	if [ -z "$desktop" ]; then
		warn "Desktop entry not found; skip GUI launcher patch"
		return 0
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would patch desktop entry: $desktop"
		return 0
	fi

	backup="${desktop}.bak.$(date +%Y%m%d%H%M%S)"
	run cp "$desktop" "$backup"

	# Replace Exec= line to use zed-secure
	sed "s|^Exec=.*|Exec=$ZED_SECURE %U|" "$backup" >"$desktop"
	log "Patched desktop entry: $desktop (backup: $backup)"
}

# --- Endpoint blocklist ---

apply_hosts_blocklist() {
	[ "$ENABLE_ENDPOINT_BLOCKLIST" -eq 1 ] || return 0

	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would append hosts blocklist to /etc/hosts (requires root)"
		for domain in $BLOCKLIST_DOMAINS; do
			[ -n "$domain" ] || continue
			printf '[dry-run] 0.0.0.0 %s\n' "$domain"
		done
		return 0
	fi

	if [ ! -w /etc/hosts ]; then
		tmp=$(mktemp)
		{
			printf '%s\n' "$HOSTS_MARKER_BEGIN"
			for domain in $BLOCKLIST_DOMAINS; do
				[ -n "$domain" ] || continue
				printf '0.0.0.0 %s\n' "$domain"
			done
			printf '%s\n' "$HOSTS_MARKER_END"
		} >"$tmp"
		run sudo sh -c "grep -q '$HOSTS_MARKER_BEGIN' /etc/hosts 2>/dev/null || cat '$tmp' >> /etc/hosts"
		rm -f "$tmp"
	else
		if ! grep -q "$HOSTS_MARKER_BEGIN" /etc/hosts 2>/dev/null; then
			{
				printf '%s\n' "$HOSTS_MARKER_BEGIN"
				for domain in $BLOCKLIST_DOMAINS; do
					[ -n "$domain" ] || continue
					printf '0.0.0.0 %s\n' "$domain"
				done
				printf '%s\n' "$HOSTS_MARKER_END"
			} >>/etc/hosts
		fi
	fi
	log "Applied /etc/hosts blocklist (best-effort, exact domains only)"
}

apply_nft_blocklist() {
	# Endpoint blocklist uses /etc/hosts only. Remove legacy global nft rules
	# (inet zed_privacy output drop) from older installs — they affected all processes.
	[ "$ENABLE_ENDPOINT_BLOCKLIST" -eq 1 ] || return 0

	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would remove legacy nft table inet zed_privacy (if any); endpoint blocklist is hosts-only"
		return 0
	fi

	remove_nft_blocklist
	warn "Endpoint blocklist is /etc/hosts only (no global nft rules); use --enable-network-sandbox for process isolation"
	log "Endpoint blocklist: hosts-only (legacy nft table removed if present)"
}

remove_hosts_blocklist() {
	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would remove hosts blocklist markers from /etc/hosts"
		return 0
	fi

	remove_cmd="sed -i '/$HOSTS_MARKER_BEGIN/,/$HOSTS_MARKER_END/d' /etc/hosts"
	if [ "$(id -u)" -eq 0 ]; then
		run sh -c "$remove_cmd"
	else
		run sudo sh -c "$remove_cmd"
	fi
}

remove_nft_blocklist() {
	have nft || return 0
	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would delete nft table inet zed_privacy"
		return 0
	fi
	if [ "$(id -u)" -eq 0 ]; then
		run nft delete table inet zed_privacy 2>/dev/null || true
	else
		run sudo nft delete table inet zed_privacy 2>/dev/null || true
	fi
}

apply_uid_wide_strict_firewall() {
	[ "$UID_WIDE_STRICT_FIREWALL" -eq 1 ] || return 0

	warn "UID-wide strict firewall blocks ALL outbound traffic for UID $(id -u)"
	warn "This affects every process run by your user, not just Zed."

	if ! have nft; then
		die "nft required for --uid-wide-strict-firewall"
	fi

	uid=$(id -u)
	if [ "$DRY_RUN" -eq 1 ]; then
		log "Would create nft rules blocking outbound for uid $uid except loopback"
		return 0
	fi

	nft_script=$(mktemp)
	cat >"$nft_script" <<EOF
add table inet zed_uid_strict
delete table inet zed_uid_strict
add table inet zed_uid_strict
add chain inet zed_uid_strict output { type filter hook output priority 0; policy accept; }
add rule inet zed_uid_strict output meta skuid $uid ip daddr != 127.0.0.0/8 drop
EOF

	if [ "$(id -u)" -eq 0 ]; then
		run nft -f "$nft_script"
	else
		run sudo nft -f "$nft_script"
	fi
	rm -f "$nft_script"
}

# --- Uninstall ---

do_uninstall() {
	log "Uninstalling zed-secure components"

	if [ -f "$ZED_SECURE" ]; then
		run rm -f "$ZED_SECURE"
	fi

	# Restore desktop from latest backup if present (all known release channels)
	for desktop_id in dev.zed.Zed dev.zed.Zed-Preview dev.zed.Zed-Nightly dev.zed.Zed-Dev; do
		for candidate in \
			"$XDG_DATA_HOME/applications/${desktop_id}.desktop" \
			"$HOME/.local/share/applications/${desktop_id}.desktop"; do
			latest=$(ls -t "${candidate}.bak."* 2>/dev/null | head -n1 || true)
			if [ -n "$latest" ]; then
				run cp "$latest" "$candidate"
				log "Restored desktop entry from $latest"
			fi
		done
	done

	remove_hosts_blocklist
	remove_nft_blocklist

	log "Uninstall complete. Zed itself was NOT removed."
	log "To remove Zed: ~/.local/bin/zed --uninstall"
}

# --- Summary ---

print_summary() {
	cat <<EOF

=== Zed Secure Install Summary ===

Config:     $ZED_SETTINGS
Wrapper:    $ZED_SECURE
Zed binary: $ZED_APP_BIN
Channel:    $ZED_CHANNEL
AI mode:    $( [ "$DISABLE_AI" -eq 1 ] && echo "disabled" || echo "local OpenAI-compatible" )
EOF

	if [ "$DISABLE_AI" -eq 0 ]; then
		printf 'LLM API:    %s\n' "$ZED_LLM_API_URL"
		printf 'LLM completions: %s\n' "$ZED_LLM_COMPLETIONS_URL"
		printf 'LLM model:  %s\n' "$ZED_LLM_MODEL"
	fi

	printf 'Sandbox:    %s\n' "$( [ "$ENABLE_NETWORK_SANDBOX" -eq 1 ] && echo "enabled (systemd-run localhost-only)" || echo "disabled" )"
	printf 'Blocklist:  %s\n' "$( [ "$ENABLE_ENDPOINT_BLOCKLIST" -eq 1 ] && echo "enabled (hosts only; no global nft rules)" || echo "disabled" )"

	cat <<'EOF'

Launch Zed securely:
  zed-secure .

Post-install checks:
  sh -n scripts/install-zed-secure.sh
  grep -E 'telemetry|auto_update|show_sign_in' "$XDG_CONFIG_HOME/zed/settings.json"
  zed-secure --version

IMPORTANT limitations:
  - Do NOT sign in to Zed account or add cloud API keys
  - Settings alone do NOT guarantee zero network egress with AI enabled
  - Local-AI installs enable network sandbox by default; use --no-network-sandbox to opt out
  - Endpoint blocklist is hosts-only (no global nft rules) and does NOT replace sandbox
  - --uid-wide-strict-firewall is a separate dangerous option (UID-wide nft, not endpoint blocklist)
  - Training data opt-in has no settings key (UI toggle only)
  - Extensions and language servers may make network requests

EOF
}

# --- Main ---

main() {
	parse_args "$@"
	apply_local_ai_sandbox_defaults

	if [ "$UNINSTALL" -eq 1 ]; then
		if [ "$DISABLE_ENDPOINT_BLOCKLIST" -eq 1 ] || [ "$UNINSTALL" -eq 1 ]; then
			remove_hosts_blocklist
			remove_nft_blocklist
		fi
		do_uninstall
		exit 0
	fi

	if [ "$DISABLE_ENDPOINT_BLOCKLIST" -eq 1 ]; then
		remove_hosts_blocklist
		remove_nft_blocklist
		if [ "$ENABLE_ENDPOINT_BLOCKLIST" -eq 0 ] && [ "$DISABLE_AI" -eq 0 ] && [ -z "$ZED_LLM_MODEL" ] && [ "$INSTALL_DEPS" -eq 0 ]; then
			# Only blocklist removal requested
			log "Endpoint blocklist removed"
			exit 0
		fi
	fi

	validate_zed_channel
	resolve_zed_app_paths

	validate_llm_urls

	detect_platform
	check_glibc
	check_download_tool
	check_vulkan
	check_inotify

	if ! check_deps; then
		if [ "$INSTALL_DEPS" -eq 0 ]; then
			warn "Some dependencies missing; continuing anyway (Zed may not work correctly)"
		fi
	fi
	install_deps

	check_sandbox_available

	install_zed
	resolve_zed_app_paths
	if [ "$DRY_RUN" -eq 0 ] && [ ! -x "$ZED_APP_BIN" ]; then
		die "Zed binary not found under $ZED_APP_DIR after install (channel=$ZED_CHANNEL). Check upstream install output."
	fi
	write_settings
	write_zed_secure_wrapper
	patch_desktop_entry

	apply_hosts_blocklist
	apply_nft_blocklist
	apply_uid_wide_strict_firewall

	print_summary
}

main "$@"
