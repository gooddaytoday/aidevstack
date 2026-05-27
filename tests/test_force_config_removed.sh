#!/bin/sh
# R7: --force-config removed; backup-on-overwrite unchanged
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# --force-config must be rejected
out=$("$INSTALLER" --force-config --disable-ai --dry-run 2>&1) && \
	fail '--force-config should exit non-zero'
case "$out" in
*unknown\ option*--force-config*) ;;
*) fail "expected unknown option for --force-config, got: $out" ;;
esac
printf 'OK: --force-config rejected as unknown option\n'

# Existing settings.json: dry-run shows backup + would write
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
mkdir -p "$tmp/zed"
printf '{"user_key":true}\n' >"$tmp/zed/settings.json"

out=$(XDG_CONFIG_HOME=$tmp "$INSTALLER" --disable-ai --dry-run 2>&1) || \
	fail 'dry-run with existing settings failed'

if ! printf '%s\n' "$out" | grep -q '\[dry-run\].*cp.*settings.json'; then
	fail 'expected [dry-run] cp for settings backup'
fi
if ! printf '%s\n' "$out" | grep -q 'Would write.*settings.json'; then
	fail 'expected Would write settings.json in dry-run'
fi
printf 'OK: existing settings -> dry-run backup + would write\n'

# --help must not mention --force-config
if "$INSTALLER" --help 2>&1 | grep -q 'force-config'; then
	fail '--help still mentions --force-config'
fi
printf 'OK: --help has no --force-config\n'

printf 'All force-config removal tests passed.\n'
