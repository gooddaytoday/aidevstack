#!/bin/sh
# Run all install-zed-secure installer tests
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

printf '==> syntax check: %s\n' "$INSTALLER"
sh -n "$INSTALLER"
for preset in "$ROOT"/scripts/install-zed-no-ai.sh "$ROOT"/scripts/install-zed-local-llm.sh \
	"$ROOT"/scripts/zed-security-settings.sh; do
	printf '==> syntax check: %s\n' "$preset"
	sh -n "$preset"
done

failed=0
discovered=0
for test_script in "$ROOT"/tests/test_*.sh; do
	[ -f "$test_script" ] || continue
	discovered=$((discovered + 1))
	printf '\n==> %s\n' "$test_script"
	if ! sh "$test_script"; then
		failed=$((failed + 1))
	fi
done

if [ "$discovered" -eq 0 ]; then
	printf '\nNo test scripts discovered under %s/tests.\n' "$ROOT" >&2
	exit 1
fi

if [ "$failed" -ne 0 ]; then
	printf '\n%d test script(s) failed.\n' "$failed" >&2
	exit 1
fi

printf '\nAll tests passed.\n'
