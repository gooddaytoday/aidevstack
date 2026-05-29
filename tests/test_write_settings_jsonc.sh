#!/bin/sh
# write_settings / repair / refresh-llm via enforce path (JSONC, infer template)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"
ENFORCE="$ROOT/scripts/zed-security-settings.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

if ! command -v jq >/dev/null 2>&1; then
	printf 'SKIP: jq required\n'
	exit 0
fi

# shellcheck source=/dev/null
. "$ENFORCE"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
mkdir -p "$tmp/zed"

# Install on Zed-style JSONC settings preserves custom keys
cat >"$tmp/zed/settings.json" <<'EOF'
{
  "custom_marker": "keep-me",
  "telemetry": { "metrics": true, "diagnostics": true, },
}
EOF

XDG_CONFIG_HOME=$tmp "$INSTALLER" --disable-ai >/dev/null 2>&1 \
	|| fail 'install on JSONC settings failed'

metrics=$(jq -r '.telemetry.metrics' "$tmp/zed/settings.json")
marker=$(jq -r '.custom_marker' "$tmp/zed/settings.json")
[ "$metrics" = "false" ] || fail "JSONC install: expected metrics false, got $metrics"
[ "$marker" = "keep-me" ] || fail "JSONC install: custom_marker lost, got $marker"
printf 'OK: install on JSONC settings via enforce path\n'

# --refresh-llm-config overwrites language_models, keeps custom_theme
cat >"$tmp/zed/settings.json" <<'EOF'
{
  "custom_theme": "my-theme",
  "telemetry": { "metrics": true, "diagnostics": true },
  "language_models": { "openai_compatible": { "Old": { "api_url": "http://old/v1" } } }
}
EOF
XDG_CONFIG_HOME=$tmp ZED_LLM_MODEL=test-model ZED_LLM_PROVIDER_NAME=LocalLLM \
	"$INSTALLER" --refresh-llm-config --llm-model test-model >/dev/null 2>&1 \
	|| fail '--refresh-llm-config failed'

theme=$(jq -r '.custom_theme' "$tmp/zed/settings.json")
provider=$(jq -r '.language_models.openai_compatible.LocalLLM.available_models[0].name' "$tmp/zed/settings.json")
metrics=$(jq -r '.telemetry.metrics' "$tmp/zed/settings.json")
[ "$theme" = "my-theme" ] || fail "refresh-llm: theme lost ($theme)"
[ "$provider" = "test-model" ] || fail "refresh-llm: model not updated ($provider)"
[ "$metrics" = "false" ] || fail "refresh-llm: telemetry not fixed ($metrics)"
printf 'OK: --refresh-llm-config preserves theme, updates LLM\n'

# --repair-settings without template infers disable_ai from settings
rm -f "$tmp/zed/settings.zed-secure-template.json"
rm -rf "$tmp/share-zed-secure" 2>/dev/null || true
cat >"$tmp/zed/settings.json" <<'EOF'
{
  "disable_ai": true,
  "telemetry": { "metrics": true, "diagnostics": true },
  "auto_update": true
}
EOF
HOME=$tmp XDG_CONFIG_HOME=$tmp \
	"$INSTALLER" --repair-settings >/dev/null 2>&1 \
	|| fail '--repair-settings infer disable_ai failed'

metrics=$(jq -r '.telemetry.metrics' "$tmp/zed/settings.json")
disable_ai=$(jq -r '.disable_ai' "$tmp/zed/settings.json")
[ "$metrics" = "false" ] || fail "repair infer: metrics=$metrics"
[ "$disable_ai" = "true" ] || fail "repair infer: disable_ai reset to $disable_ai"
tpl_disable=$(jq -r '.disable_ai' "$tmp/zed/settings.zed-secure-template.json")
[ "$tpl_disable" = "true" ] || fail "repair infer: template disable_ai=$tpl_disable"
printf 'OK: --repair-settings infers disable_ai without template\n'

# repair without template and unreadable settings fails
rm -f "$tmp/zed/settings.zed-secure-template.json"
printf '{ broken json\n' >"$tmp/zed/settings.json"
if HOME=$tmp XDG_CONFIG_HOME=$tmp \
	"$INSTALLER" --repair-settings >/dev/null 2>&1; then
	fail 'repair should fail on unreadable settings without template'
fi
printf 'OK: repair dies on unreadable settings without template\n'

# enforce exit 2 on sed-only JSONC (strict verify fails)
jsonc_sed="$tmp/sed-only.json"
cat >"$jsonc_sed" <<'EOF'
{
  "telemetry": { "diagnostics": true, "metrics": true, },
}
EOF
ZED_SECURE_TEMPLATE_SHARE="$tmp/no-share-template.json" \
	ZED_ENFORCE_DRY_RUN=0 enforce_security_settings "$jsonc_sed" "/nonexistent/template.json" || rc=$?
rc=${rc:-0}
[ "$rc" -eq 2 ] || fail "expected enforce exit 2 for sed-only, got $rc"
if ZED_SECURE_TEMPLATE_SHARE="$tmp/no-share-template.json" \
	ZED_ENFORCE_STRICT_VERIFY=1 sh "$ENFORCE" "$jsonc_sed" "/nonexistent/template.json" >/dev/null 2>&1; then
	fail 'strict verify should fail on exit 2'
fi
printf 'OK: enforce exit 2 for sed-only without template\n'

printf 'All write_settings JSONC tests passed.\n'
