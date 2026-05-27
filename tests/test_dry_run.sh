#!/bin/sh
# R14: dry-run must not write settings or /etc/hosts
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
mkdir -p "$tmp/zed"
printf '{"unchanged":true}\n' >"$tmp/zed/settings.json"

out=$(XDG_CONFIG_HOME=$tmp "$INSTALLER" --disable-ai --dry-run 2>&1) \
	|| fail 'dry-run failed'

if ! printf '%s\n' "$out" | grep -q '\[dry-run\]'; then
	fail 'dry-run output should contain [dry-run] markers'
fi
printf 'OK: dry-run output contains [dry-run] markers\n'

if ! cmp -s "$tmp/zed/settings.json" - <<'EOF'
{"unchanged":true}
EOF
then
	fail 'dry-run modified existing settings.json'
fi
printf 'OK: existing settings.json unchanged\n'

tmp2=$(mktemp -d)
trap 'rm -rf "$tmp" "$tmp2"' EXIT INT HUP TERM
mkdir -p "$tmp2/zed"

XDG_CONFIG_HOME=$tmp2 "$INSTALLER" --disable-ai --dry-run >/dev/null 2>&1 \
	|| fail 'dry-run without existing settings failed'

if [ -f "$tmp2/zed/settings.json" ]; then
	fail 'dry-run should not create settings.json'
fi
printf 'OK: dry-run did not create settings.json\n'

out=$(XDG_CONFIG_HOME=$tmp "$INSTALLER" --disable-ai \
	--enable-endpoint-blocklist --dry-run 2>&1) || fail 'blocklist dry-run failed'

if ! printf '%s\n' "$out" | grep -q 'Would append hosts blocklist'; then
	fail 'blocklist dry-run should log Would append hosts blocklist'
fi
if printf '%s\n' "$out" | grep -q 'Applied /etc/hosts blocklist'; then
	fail 'blocklist dry-run should not log Applied /etc/hosts'
fi
printf 'OK: endpoint blocklist dry-run is non-destructive\n'

printf 'All dry-run tests passed.\n'
