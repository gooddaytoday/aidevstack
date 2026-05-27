#!/bin/sh
# R12: confirm guardrails for --uid-wide-strict-firewall
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

out=$("$INSTALLER" --uid-wide-strict-firewall --disable-ai --dry-run 2>&1) && \
	fail '--uid-wide-strict-firewall without accept should exit non-zero'
case "$out" in
*--i-accept-uid-wide-firewall*) ;;
*) fail "expected --i-accept-uid-wide-firewall error, got: $out" ;;
esac
printf 'OK: --uid-wide-strict-firewall without accept rejected\n'

out=$("$INSTALLER" --i-accept-uid-wide-firewall --disable-ai --dry-run 2>&1) && \
	fail '--i-accept-uid-wide-firewall without main flag should exit non-zero'
case "$out" in
*requires\ --uid-wide-strict-firewall*) ;;
*) fail "expected requires --uid-wide-strict-firewall error, got: $out" ;;
esac
printf 'OK: --i-accept-uid-wide-firewall without main flag rejected\n'

out=$("$INSTALLER" \
	--uid-wide-strict-firewall \
	--i-accept-uid-wide-firewall \
	--disable-ai \
	--dry-run 2>&1) || fail 'accepted dry-run failed'
if ! printf '%s\n' "$out" | grep -q 'Would create nft rules blocking outbound'; then
	fail 'expected Would create nft rules in dry-run output'
fi
printf 'OK: both flags + dry-run succeeds\n'

help=$("$INSTALLER" --help 2>&1) || fail '--help failed'
case "$help" in
*--uid-wide-strict-firewall*) ;;
*) fail '--help missing --uid-wide-strict-firewall' ;;
esac
case "$help" in
*--i-accept-uid-wide-firewall*) ;;
*) fail '--help missing --i-accept-uid-wide-firewall' ;;
esac
case "$help" in
*--yes*) ;;
*) fail '--help missing --yes' ;;
esac
printf 'OK: --help lists firewall confirm flags\n'

printf 'All UID firewall confirm tests passed.\n'
