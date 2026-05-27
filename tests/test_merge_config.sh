#!/bin/sh
# R8: deep merge for --merge-config with secure-template override
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

if ! command -v jq >/dev/null 2>&1; then
	printf 'SKIP: jq required for merge-config tests\n'
	exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
mkdir -p "$tmp/zed"

cat >"$tmp/zed/settings.json" <<'EOF'
{
  "custom_theme": "user-dark",
  "telemetry": {
    "metrics": true,
    "diagnostics": true,
    "extra_old": true
  },
  "title_bar": {
    "show_sign_in": true,
    "show_user_menu": true
  },
  "editor": {
    "tab_size": 4,
    "soft_wrap": "none"
  }
}
EOF

XDG_CONFIG_HOME=$tmp "$INSTALLER" --disable-ai --merge-config >/dev/null 2>&1 \
	|| fail 'merge-config install failed'

if [ ! -f "$tmp/zed/settings.json" ]; then
	fail 'settings.json missing after merge-config'
fi

metrics=$(jq -r '.telemetry.metrics' "$tmp/zed/settings.json")
diagnostics=$(jq -r '.telemetry.diagnostics' "$tmp/zed/settings.json")
auto_update=$(jq -r '.auto_update' "$tmp/zed/settings.json")
disable_ai=$(jq -r '.disable_ai' "$tmp/zed/settings.json")
show_sign_in=$(jq -r '.title_bar.show_sign_in' "$tmp/zed/settings.json")
custom_theme=$(jq -r '.custom_theme' "$tmp/zed/settings.json")
tab_size=$(jq -r '.editor.tab_size' "$tmp/zed/settings.json")

[ "$metrics" = "false" ] || fail "expected telemetry.metrics=false, got $metrics"
[ "$diagnostics" = "false" ] || fail "expected telemetry.diagnostics=false, got $diagnostics"
[ "$auto_update" = "false" ] || fail "expected auto_update=false, got $auto_update"
[ "$disable_ai" = "true" ] || fail "expected disable_ai=true, got $disable_ai"
[ "$show_sign_in" = "false" ] || fail "expected title_bar.show_sign_in=false, got $show_sign_in"
[ "$custom_theme" = "user-dark" ] || fail "expected custom_theme preserved, got $custom_theme"
[ "$tab_size" = "4" ] || fail "expected editor.tab_size preserved, got $tab_size"

if jq -e '.telemetry.extra_old' "$tmp/zed/settings.json" >/dev/null 2>&1; then
	fail 'telemetry.extra_old should not survive secure-template overwrite'
fi

printf 'OK: security keys overwritten from template\n'
printf 'OK: custom user keys preserved\n'
printf 'All merge-config tests passed.\n'
