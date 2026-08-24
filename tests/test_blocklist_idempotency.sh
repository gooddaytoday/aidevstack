#!/bin/sh
# Endpoint blocklist idempotency (R6)
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

"$INSTALLER" --disable-ai --enable-endpoint-blocklist --dry-run >/dev/null 2>&1 \
	|| fail 'first dry-run with blocklist failed'
"$INSTALLER" --disable-ai --enable-endpoint-blocklist --dry-run >/dev/null 2>&1 \
	|| fail 'second dry-run with blocklist failed'
printf 'OK: double dry-run with --enable-endpoint-blocklist exits 0\n'

out=$("$INSTALLER" --disable-ai --enable-endpoint-blocklist --dry-run 2>&1) \
	|| fail 'blocklist dry-run failed'

assert_contains 'hosts blocklist message' 'Would append hosts blocklist' "$out"
assert_contains 'legacy nft cleanup message' 'Would remove legacy nft table inet zed_privacy' "$out"
assert_contains 'summary blocklist enabled' 'Blocklist:  enabled (hosts only; no global nft rules)' "$out"
assert_contains 'hosts-only dry-run message' 'endpoint blocklist is hosts-only' "$out"
printf 'OK: dry-run output shows hosts-only blocklist semantics\n'

disable_out=$("$INSTALLER" --disable-endpoint-blocklist --dry-run 2>&1) \
	|| fail 'disable-only dry-run failed'
assert_contains 'disable hosts cleanup' 'Would remove hosts blocklist markers' "$disable_out"
assert_contains 'disable nft cleanup' 'Would delete nft table inet zed_privacy' "$disable_out"
printf 'OK: --disable-endpoint-blocklist dry-run exits 0\n'

printf 'All blocklist idempotency tests passed.\n'
