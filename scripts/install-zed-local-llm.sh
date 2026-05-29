#!/bin/sh
# install-zed-local-llm.sh — Preset: local LLM with deps, blocklist, network sandbox
# Wraps install-zed-secure.sh with recommended flags from README.

set -eu

usage() {
	cat <<'EOF' >&2
Usage: install-zed-local-llm.sh MODEL [OPTIONS]

Install Zed Secure for a local OpenAI-compatible LLM (recommended setup).
MODEL must be the first argument (cannot start with "-").
OPTIONS are forwarded to install-zed-secure.sh (e.g. --dry-run, --merge-config).

Preset always passes: --install-deps (may run sudo), --enable-endpoint-blocklist,
loopback LLM URL, and network sandbox (via main installer when --llm-model is set).
Forwarded flags can override preset behavior (e.g. --no-network-sandbox).

Examples:
  ./install-zed-local-llm.sh your-model-name
  ./install-zed-local-llm.sh qwen2.5-coder --dry-run
EOF
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
esac

if [ $# -lt 1 ]; then
	usage
	exit 1
fi

MODEL=$1
shift

case "$MODEL" in
-*)
	printf 'ERROR: MODEL must be the first argument and cannot start with "-".\n' >&2
	case "$MODEL" in
	--dry-run)
		printf 'Hint: put the model name first: ./install-zed-local-llm.sh your-model-name --dry-run\n' >&2
		;;
	*)
		printf 'Hint: ./install-zed-local-llm.sh your-model-name [OPTIONS]\n' >&2
		;;
	esac
	usage
	exit 1
	;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
INSTALLER="$SCRIPT_DIR/install-zed-secure.sh"

if [ ! -f "$INSTALLER" ]; then
	printf 'ERROR: missing %s\n' "$INSTALLER" >&2
	exit 1
fi

exec sh "$INSTALLER" \
	--install-deps \
	--llm-model "$MODEL" \
	--llm-api-url 'http://127.0.0.1:8080/v1?api_version=2024' \
	--enable-endpoint-blocklist \
	"$@"
