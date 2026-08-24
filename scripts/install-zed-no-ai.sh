#!/bin/sh
# install-zed-no-ai.sh — Preset: maximum privacy, no local LLM
# Wraps install-zed-secure.sh with --disable-ai. Extra flags are forwarded.

set -eu

usage() {
	cat <<'EOF' >&2
Usage: install-zed-no-ai.sh [OPTIONS]

Install Zed Secure with AI disabled (maximum privacy).
OPTIONS are forwarded to install-zed-secure.sh (e.g. --dry-run, --channel, --offline).

Preset always passes --disable-ai first; forwarded flags can change other behavior
(e.g. --channel, --merge-config). AI stays disabled even if --llm-model is passed.

Examples:
  ./install-zed-no-ai.sh
  ./install-zed-no-ai.sh --dry-run
EOF
}

case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
INSTALLER="$SCRIPT_DIR/install-zed-secure.sh"

if [ ! -f "$INSTALLER" ]; then
	printf 'ERROR: missing %s\n' "$INSTALLER" >&2
	exit 1
fi

exec sh "$INSTALLER" --disable-ai "$@"
