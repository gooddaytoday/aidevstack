#!/bin/sh
# Loopback and URL validation (R4, R5)
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

assert_url_reject_invalid() {
	label=$1
	url=$2
	out=$("$INSTALLER" --llm-model test-model --llm-api-url "$url" --dry-run 2>&1) && \
		fail "$label: expected reject for $url"
	if ! printf '%s\n' "$out" | grep -q 'invalid'; then
		fail "$label: expected invalid characters error for $url"
	fi
	printf 'OK: reject invalid %s\n' "$label"
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

assert_completions_url() {
	label=$1
	api_url=$2
	expected=$3
	out=$("$INSTALLER" --llm-model test-model --llm-api-url "$api_url" --dry-run 2>&1) || \
		fail "$label: dry-run failed for $api_url"
	if ! printf '%s\n' "$out" | grep -q "LLM completions: $expected"; then
		fail "$label: expected completions URL $expected"
	fi
	printf 'OK: completions %s\n' "$label"
}

assert_url_accept '127.0.0.1 with port' 'http://127.0.0.1:8080/v1'
assert_url_accept '127.0.0.1 with path' 'http://127.0.0.1/v1'
assert_url_accept 'localhost with port' 'http://localhost:8080/v1'
assert_url_accept 'IPv6 loopback with port' 'http://[::1]:8080/v1'
assert_url_accept 'IPv6 loopback with path' 'http://[::1]/v1'

assert_url_reject 'LAN IP' 'http://192.168.1.1:8080/v1'
assert_url_reject 'remote host' 'http://evil.com/v1'

assert_url_opt_out 'LAN IP with override' 'http://192.168.1.1:8080/v1'

# R5: query/path validation
assert_url_accept 'query param api_version' 'http://127.0.0.1:8080/v1?api_version=2024'
assert_url_accept 'multiple query params' 'http://127.0.0.1:8080/v1?a=1&b=2'
assert_url_accept 'percent-encoded query' 'http://127.0.0.1:8080/v1?key=hello%20world'
assert_url_accept 'IPv6 with query' 'http://[::1]:8080/v1?api_version=2024'

assert_url_reject 'remote host with query' 'http://evil.com/v1?foo=bar'

assert_url_reject_invalid 'space in URL' 'http://127.0.0.1:8080/v1?key=hello world'
assert_url_reject_invalid 'userinfo @' 'http://user@127.0.0.1:8080/v1'
assert_url_reject_invalid 'double quote' 'http://127.0.0.1:8080/v1?q="bad"'

assert_completions_url 'query preserved on completions' \
	'http://127.0.0.1:8080/v1?api_version=2024' \
	'http://127.0.0.1:8080/v1/completions?api_version=2024'

printf 'All URL validation tests passed.\n'
