#!/bin/sh
# Loopback URL validation (R4)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_url_accept() {
	label=$1
	url=$2
	if ! "$INSTALLER" --llm-model test-model --llm-api-url "$url" --dry-run >/dev/null 2>&1; then
		fail "$label: expected accept for $url"
	fi
	printf 'OK: accept %s\n' "$label"
}

assert_url_reject() {
	label=$1
	url=$2
	out=$("$INSTALLER" --llm-model test-model --llm-api-url "$url" --dry-run 2>&1) && \
		fail "$label: expected reject for $url"
	if ! printf '%s\n' "$out" | grep -q 'must be loopback'; then
		fail "$label: expected loopback error for $url"
	fi
	printf 'OK: reject %s\n' "$label"
}

assert_url_opt_out() {
	label=$1
	url=$2
	if ! "$INSTALLER" --llm-model test-model --llm-api-url "$url" \
		--allow-nonlocal-llm --dry-run >/dev/null 2>&1; then
		fail "$label: expected accept with --allow-nonlocal-llm for $url"
	fi
	printf 'OK: opt-out %s\n' "$label"
}

assert_url_accept '127.0.0.1 with port' 'http://127.0.0.1:8080/v1'
assert_url_accept '127.0.0.1 with path' 'http://127.0.0.1/v1'
assert_url_accept 'localhost with port' 'http://localhost:8080/v1'
assert_url_accept 'IPv6 loopback with port' 'http://[::1]:8080/v1'
assert_url_accept 'IPv6 loopback with path' 'http://[::1]/v1'

assert_url_reject 'LAN IP' 'http://192.168.1.1:8080/v1'
assert_url_reject 'remote host' 'http://evil.com/v1'

assert_url_opt_out 'LAN IP with override' 'http://192.168.1.1:8080/v1'

printf 'All URL validation tests passed.\n'
