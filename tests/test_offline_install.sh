#!/bin/sh
# R9: offline install via ZED_BUNDLE_PATH without network fetch
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_not_contains() {
	label=$1
	needle=$2
	haystack=$3
	if printf '%s\n' "$haystack" | grep -q "$needle"; then
		fail "$label: output must not contain '$needle'"
	fi
}

assert_contains() {
	label=$1
	needle=$2
	haystack=$3
	if ! printf '%s\n' "$haystack" | grep -q "$needle"; then
		fail "$label: expected output to contain '$needle'"
	fi
}

out=$(ZED_BUNDLE_PATH=/tmp/fake-zed-linux-x86_64.tar.gz \
	"$INSTALLER" --disable-ai --offline --dry-run 2>&1) \
	|| fail 'offline dry-run with ZED_BUNDLE_PATH failed'

assert_not_contains 'no curl to install.sh' \
	'curl -f https://zed.dev/install.sh' "$out"
assert_not_contains 'no curl to install.sh' \
	'curl -f https://zed.dev/install.sh | sh' "$out"
assert_contains 'local bundle message' 'Installing Zed from local bundle' "$out"
assert_contains 'tar extract' 'tar -xzf /tmp/fake-zed-linux-x86_64.tar.gz' "$out"
assert_contains 'zed symlink' 'ln -sf' "$out"
printf 'OK: ZED_BUNDLE_PATH dry-run uses local install without curl\n'

out=$("$INSTALLER" --disable-ai --offline --dry-run 2>&1) && \
	fail '--offline without bundle should exit non-zero'
case "$out" in
*ZED_BUNDLE_PATH*) ;;
*) fail "expected ZED_BUNDLE_PATH error, got: $out" ;;
esac
printf 'OK: --offline without bundle rejected\n'

printf 'All offline install tests passed.\n'
