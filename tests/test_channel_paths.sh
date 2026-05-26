#!/bin/sh
# Channel-specific app paths (R2)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_path() {
	channel=$1
	expected_substr=$2
	out=$(ZED_CHANNEL=$channel "$INSTALLER" --disable-ai --dry-run 2>&1) || fail "dry-run failed for channel=$channel"
	if ! printf '%s\n' "$out" | grep -q "$expected_substr"; then
		fail "channel=$channel: expected path containing '$expected_substr' in output"
	fi
	printf 'OK: channel=%s -> %s\n' "$channel" "$expected_substr"
}

assert_path stable 'zed.app'
assert_path preview 'zed-preview.app'
assert_path nightly 'zed-nightly.app'
assert_path dev 'zed-dev.app'

if ZED_CHANNEL=stable "$INSTALLER" --channel bogus --disable-ai --dry-run 2>/dev/null; then
	fail "unknown channel should exit non-zero"
fi
printf 'OK: unknown channel rejected\n'

printf 'All channel path tests passed.\n'
