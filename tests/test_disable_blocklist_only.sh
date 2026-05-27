#!/bin/sh
# R11: --disable-endpoint-blocklist without full reinstall
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

assert_not_contains() {
	label=$1
	needle=$2
	haystack=$3
	if printf '%s\n' "$haystack" | grep -q "$needle"; then
		fail "$label: output must not contain '$needle'"
	fi
}

out=$("$INSTALLER" --disable-endpoint-blocklist --dry-run 2>&1) \
	|| fail 'disable-only dry-run failed'
assert_contains 'hosts cleanup' 'Would remove hosts blocklist markers' "$out"
assert_contains 'removed message' 'Endpoint blocklist removed' "$out"
assert_not_contains 'no settings write' 'Would write' "$out"
assert_not_contains 'no wrapper write' 'zed-secure' "$out"
assert_not_contains 'no install' 'Installing Zed' "$out"
printf 'OK: --disable-endpoint-blocklist dry-run exits without install side effects\n'

out=$("$INSTALLER" --disable-endpoint-blocklist --disable-ai --dry-run 2>&1) \
	|| fail 'disable + disable-ai dry-run failed'
assert_contains 'hosts cleanup combo' 'Would remove hosts blocklist markers' "$out"
assert_contains 'removed message combo' 'Endpoint blocklist removed' "$out"
assert_not_contains 'no settings write combo' 'Would write' "$out"
assert_not_contains 'no wrapper write combo' 'Would write' "$out"
assert_not_contains 'no install combo' 'Installing Zed' "$out"
printf 'OK: --disable-endpoint-blocklist --disable-ai dry-run exits without reinstall\n'

out=$("$INSTALLER" --disable-endpoint-blocklist --llm-model test-model --dry-run 2>&1) \
	|| fail 'disable with llm-model dry-run failed'
assert_contains 'install with llm-model' 'Installing Zed' "$out"
printf 'OK: --disable-endpoint-blocklist with --llm-model still runs install\n'

printf 'All disable-blocklist-only tests passed.\n'
