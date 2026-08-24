#!/bin/sh
# R14: CLI parser edge cases
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

out=$("$INSTALLER" --totally-unknown-flag --dry-run 2>&1) && \
	fail 'unknown option should exit non-zero'
case "$out" in
*unknown\ option*) ;;
*) fail "expected unknown option error, got: $out" ;;
esac
printf 'OK: unknown option rejected\n'

out=$("$INSTALLER" --llm-model 2>&1) && fail '--llm-model without arg should fail'
case "$out" in
*requires\ an\ argument*) ;;
*) fail "expected requires argument for --llm-model, got: $out" ;;
esac
printf 'OK: --llm-model requires argument\n'

out=$("$INSTALLER" --channel 2>&1) && fail '--channel without arg should fail'
case "$out" in
*requires\ an\ argument*) ;;
*) fail "expected requires argument for --channel, got: $out" ;;
esac
printf 'OK: --channel requires argument\n'

"$INSTALLER" --help >/dev/null 2>&1 || fail '--help should exit 0'
help=$("$INSTALLER" --help 2>&1)
case "$help" in
*--disable-ai*) ;;
*) fail '--help missing --disable-ai' ;;
esac
case "$help" in
*--llm-model*) ;;
*) fail '--help missing --llm-model' ;;
esac
case "$help" in
*--merge-config*) ;;
*) fail '--help missing --merge-config' ;;
esac
printf 'OK: --help lists key flags\n'

out=$("$INSTALLER" --force-config --disable-ai --dry-run 2>&1) && \
	fail '--force-config should exit non-zero'
case "$out" in
*unknown\ option*--force-config*) ;;
*) fail "expected unknown option for --force-config, got: $out" ;;
esac
printf 'OK: --force-config rejected (R7 regression)\n'

printf 'All CLI parser tests passed.\n'
