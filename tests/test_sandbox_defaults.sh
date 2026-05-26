#!/bin/sh
# Network sandbox defaults for local-AI (R3)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_sandbox_enabled() {
	label=$1
	shift
	out=$("$@" 2>&1) || fail "$label: dry-run failed"
	if ! printf '%s\n' "$out" | grep -q 'Sandbox:.*enabled'; then
		fail "$label: expected Sandbox enabled in output"
	fi
	printf 'OK: %s -> sandbox enabled\n' "$label"
}

assert_sandbox_disabled() {
	label=$1
	shift
	out=$("$@" 2>&1) || fail "$label: dry-run failed"
	if ! printf '%s\n' "$out" | grep -q 'Sandbox:.*disabled'; then
		fail "$label: expected Sandbox disabled in output"
	fi
	printf 'OK: %s -> sandbox disabled\n' "$label"
}

assert_sandbox_enabled 'local-AI default' \
	"$INSTALLER" --llm-model test-model --dry-run

out=$("$INSTALLER" --llm-model test-model --no-network-sandbox --dry-run 2>&1) \
	|| fail 'opt-out dry-run failed'
if ! printf '%s\n' "$out" | grep -q 'Network sandbox DISABLED'; then
	fail 'opt-out: expected Network sandbox DISABLED warning'
fi
if ! printf '%s\n' "$out" | grep -q 'Sandbox:.*disabled'; then
	fail 'opt-out: expected Sandbox disabled in output'
fi
printf 'OK: --no-network-sandbox -> warning + sandbox disabled\n'

assert_sandbox_disabled '--disable-ai' \
	"$INSTALLER" --disable-ai --dry-run

assert_sandbox_enabled 'ZED_LLM_MODEL env' \
	env ZED_LLM_MODEL=env-model "$INSTALLER" --dry-run

if "$INSTALLER" --llm-model m --enable-network-sandbox --no-network-sandbox --dry-run \
	>/dev/null 2>&1; then
	fail 'conflicting sandbox flags should exit non-zero'
fi
printf 'OK: conflicting sandbox flags rejected\n'

printf 'All sandbox default tests passed.\n'
