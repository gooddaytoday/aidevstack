#!/bin/sh
# R10: opt-in --replace-zed-cli wrapper bypass protection
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	label=$1
	needle=$2
	haystack=$3
	if ! printf '%s\n' "$haystack" | grep -q "$needle"; then
		fail "$label: expected output to contain '$needle'"
	fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
mkdir -p "$tmp/.local/zed.app/bin" "$tmp/.local/bin" "$tmp/.config/zed"

printf '#!/bin/sh\nexit 0\n' >"$tmp/.local/zed.app/bin/zed"
chmod +x "$tmp/.local/zed.app/bin/zed"
printf '#!/bin/sh\necho upstream-zed\n' >"$tmp/.local/bin/zed"
chmod +x "$tmp/.local/bin/zed"

out=$(HOME=$tmp XDG_CONFIG_HOME="$tmp/.config" \
	"$INSTALLER" --disable-ai --replace-zed-cli --dry-run 2>&1) \
	|| fail 'replace-zed-cli dry-run failed'

assert_contains 'would replace message' 'Would replace' "$out"
assert_contains 'would backup message' 'Would backup existing' "$out"
assert_contains 'ln symlink' 'ln -sf' "$out"
printf 'OK: --replace-zed-cli dry-run shows backup and symlink actions\n'

HOME=$tmp XDG_CONFIG_HOME="$tmp/.config" \
	"$INSTALLER" --disable-ai --replace-zed-cli >/dev/null 2>&1 \
	|| fail 'replace-zed-cli install with preinstalled Zed failed'

if [ ! -L "$tmp/.local/bin/zed" ]; then
	fail 'expected ~/.local/bin/zed to be a symlink after --replace-zed-cli'
fi

target=$(readlink "$tmp/.local/bin/zed")
case "$target" in
*zed-secure) ;;
*) fail "expected zed -> zed-secure, got: $target" ;;
esac

if [ ! -x "$tmp/.local/bin/zed-secure" ]; then
	fail 'zed-secure wrapper missing after install'
fi

printf 'OK: --replace-zed-cli creates zed -> zed-secure symlink\n'
printf 'All replace-zed-cli tests passed.\n'
