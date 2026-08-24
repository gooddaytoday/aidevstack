#!/bin/sh
# Preset wrapper scripts: dry-run, usage, arg validation
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NO_AI="$ROOT/scripts/install-zed-no-ai.sh"
LOCAL_LLM="$ROOT/scripts/install-zed-local-llm.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	label=$1
	needle=$2
	haystack=$3
	case "$haystack" in
	*"$needle"*) ;;
	*) fail "$label: expected substring '$needle'" ;;
	esac
}

sh -n "$NO_AI" || fail 'syntax check install-zed-no-ai.sh'
sh -n "$LOCAL_LLM" || fail 'syntax check install-zed-local-llm.sh'

"$NO_AI" --help >/dev/null 2>&1 || fail '--help on no-ai should exit 0'
"$LOCAL_LLM" --help >/dev/null 2>&1 || fail '--help on local-llm should exit 0'
printf 'OK: preset --help exits 0\n'

out=$("$NO_AI" --dry-run 2>&1) || fail 'no-ai dry-run should exit 0'
assert_contains 'no-ai dry-run marker' '[dry-run]' "$out"
assert_contains 'no-ai AI disabled' 'AI mode:    disabled' "$out"
printf 'OK: install-zed-no-ai.sh --dry-run\n'

out=$("$NO_AI" --llm-model evil --dry-run 2>&1) || fail 'no-ai with forwarded --llm-model dry-run should exit 0'
assert_contains 'no-ai preset wins over llm-model' 'AI mode:    disabled' "$out"
printf 'OK: install-zed-no-ai.sh keeps AI disabled with forwarded --llm-model\n'

out=$("$NO_AI" --channel preview --dry-run 2>&1) || fail 'no-ai channel forward dry-run should exit 0'
assert_contains 'no-ai forwards --channel' 'channel=preview' "$out"
assert_contains 'no-ai preview binary path' 'zed-preview.app' "$out"
printf 'OK: install-zed-no-ai.sh forwards OPTIONS\n'

out=$("$LOCAL_LLM" 2>&1) && fail 'local-llm without model should exit non-zero'
assert_contains 'local-llm usage' 'MODEL must be the first argument' "$out"
printf 'OK: install-zed-local-llm.sh requires model\n'

out=$("$LOCAL_LLM" --dry-run 2>&1) && fail 'local-llm with only --dry-run should exit non-zero'
assert_contains 'local-llm reject flag as model' 'cannot start with "-"' "$out"
assert_contains 'local-llm dry-run hint' 'your-model-name --dry-run' "$out"
printf 'OK: install-zed-local-llm.sh rejects --dry-run without model\n'

out=$("$LOCAL_LLM" test-model --dry-run 2>&1) || fail 'local-llm dry-run should exit 0'
assert_contains 'local-llm dry-run marker' '[dry-run]' "$out"
assert_contains 'local-llm model in summary' 'LLM model:  test-model' "$out"
assert_contains 'local-llm AI enabled' 'AI mode:    local OpenAI-compatible' "$out"
assert_contains 'local-llm standard API URL' 'LLM API:    http://127.0.0.1:8080/v1' "$out"
assert_contains 'local-llm sandbox default' \
	'Sandbox:    requested (not verified in dry-run)' "$out"
assert_contains 'local-llm blocklist preset' 'hosts blocklist' "$out"
case "$out" in
*api_version=2024*) fail 'local-llm preset must not force a vendor-specific api_version' ;;
esac
printf 'OK: install-zed-local-llm.sh test-model --dry-run\n'

out=$(ZED_LLM_API_URL='http://localhost:8080/v1?custom=1' \
	"$LOCAL_LLM" test-model --dry-run 2>&1) || fail 'local-llm env URL dry-run should exit 0'
assert_contains 'local-llm honors ZED_LLM_API_URL' \
	'LLM API:    http://localhost:8080/v1?custom=1' "$out"
printf 'OK: install-zed-local-llm.sh honors ZED_LLM_API_URL\n'

printf 'All preset installer tests passed.\n'
