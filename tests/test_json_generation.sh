#!/bin/sh
# R14: JSON settings generation (>=10 cases)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

if ! command -v jq >/dev/null 2>&1; then
	printf 'SKIP: jq required for JSON generation tests\n'
	exit 0
fi

base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT INT HUP TERM

run_install() {
	label=$1
	shift
	case_id=$1
	shift
	cfg="$base/case-$case_id"
	mkdir -p "$cfg/zed"
	XDG_CONFIG_HOME=$cfg "$INSTALLER" "$@" >/dev/null 2>&1 \
		|| fail "$label: install failed"
	settings="$cfg/zed/settings.json"
	[ -f "$settings" ] || fail "$label: settings.json missing"
	jq empty "$settings" 2>/dev/null || fail "$label: invalid JSON"
	printf '%s' "$settings"
}

# 1. --disable-ai
settings=$(run_install 'disable-ai' 1 --disable-ai)
disable_ai=$(jq -r '.disable_ai' "$settings")
[ "$disable_ai" = "true" ] || fail "case 1: disable_ai=$disable_ai"
printf 'OK: case 1 disable_ai=true\n'

# 2. --llm-model + full model capabilities (Zed 1.4+ schema)
settings=$(run_install 'llm-model' 2 --llm-model test-model)
if ! jq -e '.language_models.openai_compatible' "$settings" >/dev/null 2>&1; then
	fail 'case 2: language_models missing'
fi
parallel=$(jq -r '.language_models.openai_compatible.LocalLLM.available_models[0].capabilities.parallel_tool_calls' "$settings")
cache_key=$(jq -r '.language_models.openai_compatible.LocalLLM.available_models[0].capabilities.prompt_cache_key' "$settings")
[ "$parallel" = "false" ] || fail "case 2: parallel_tool_calls=$parallel"
[ "$cache_key" = "false" ] || fail "case 2: prompt_cache_key=$cache_key"
printf 'OK: case 2 language_models with full capabilities\n'

# 3. --disable-local-edit-predictions
settings=$(run_install 'no-edit-predictions' 3 --llm-model m --disable-local-edit-predictions)
show_edit=$(jq -r '.show_edit_predictions' "$settings")
[ "$show_edit" = "false" ] || fail "case 3: show_edit_predictions=$show_edit"
printf 'OK: case 3 show_edit_predictions=false\n'

# 4. --do-not-hide-env-files
settings=$(run_install 'show-env-files' 4 --disable-ai --do-not-hide-env-files)
if jq -e '.file_scan_exclusions[] | select(. == "**/.env*")' "$settings" >/dev/null 2>&1; then
	fail 'case 4: .env should not be in exclusions'
fi
printf 'OK: case 4 .env not hidden\n'

# 5. default hides .env
settings=$(run_install 'hide-env-default' 5 --disable-ai)
if ! jq -e '.file_scan_exclusions[] | select(. == "**/.env*")' "$settings" >/dev/null 2>&1; then
	fail 'case 5: .env should be in exclusions'
fi
printf 'OK: case 5 .env hidden by default\n'

# 6. agent.tool_permissions with --disable-ai
settings=$(run_install 'agent-disable-ai' 6 --disable-ai)
fetch=$(jq -r '.agent.tool_permissions.tools.fetch.default' "$settings")
[ "$fetch" = "deny" ] || fail "case 6: fetch.default=$fetch"
printf 'OK: case 6 agent permissions with disable-ai\n'

# 7. telemetry keys
settings=$(run_install 'telemetry' 7 --disable-ai)
metrics=$(jq -r '.telemetry.metrics' "$settings")
diagnostics=$(jq -r '.telemetry.diagnostics' "$settings")
[ "$metrics" = "false" ] && [ "$diagnostics" = "false" ] \
	|| fail "case 7: telemetry not all false"
printf 'OK: case 7 telemetry disabled\n'

# 8. title_bar sign_in
settings=$(run_install 'title-bar' 8 --disable-ai)
sign_in=$(jq -r '.title_bar.show_sign_in' "$settings")
[ "$sign_in" = "false" ] || fail "case 8: show_sign_in=$sign_in"
printf 'OK: case 8 title_bar.sign_in false\n'

# 9. query URL preserved
settings=$(run_install 'query-url' 9 --llm-model m \
	--llm-api-url 'http://127.0.0.1:8080/v1?api_version=2024')
api_url=$(jq -r '.language_models.openai_compatible.LocalLLM.api_url' "$settings")
[ "$api_url" = 'http://127.0.0.1:8080/v1?api_version=2024' ] \
	|| fail "case 9: api_url=$api_url"
printf 'OK: case 9 query URL preserved\n'

# 10. merge-config security keys
cfg="$base/case-10"
mkdir -p "$cfg/zed"
cat >"$cfg/zed/settings.json" <<'EOF'
{
  "telemetry": { "metrics": true, "diagnostics": true },
  "custom_theme": "keep-me"
}
EOF
XDG_CONFIG_HOME=$cfg "$INSTALLER" --disable-ai --merge-config >/dev/null 2>&1 \
	|| fail 'case 10: merge-config failed'
metrics=$(jq -r '.telemetry.metrics' "$cfg/zed/settings.json")
theme=$(jq -r '.custom_theme' "$cfg/zed/settings.json")
[ "$metrics" = "false" ] || fail "case 10: metrics=$metrics"
[ "$theme" = "keep-me" ] || fail "case 10: custom_theme lost"
printf 'OK: case 10 merge-config security overwrite\n'

# 11. security-only overlay on existing settings (no --merge-config)
cfg="$base/case-11"
mkdir -p "$cfg/zed"
cat >"$cfg/zed/settings.json" <<'EOF'
{
  "custom_marker": "stay",
  "telemetry": { "metrics": true, "diagnostics": true }
}
EOF
XDG_CONFIG_HOME=$cfg "$INSTALLER" --disable-ai >/dev/null 2>&1 \
	|| fail 'case 11: security overlay install failed'
metrics=$(jq -r '.telemetry.metrics' "$cfg/zed/settings.json")
marker=$(jq -r '.custom_marker' "$cfg/zed/settings.json")
[ "$metrics" = "false" ] || fail "case 11: metrics=$metrics"
[ "$marker" = "stay" ] || fail "case 11: custom_marker lost"
printf 'OK: case 11 security-only overlay preserves custom keys\n'

printf 'All JSON generation tests passed (11 cases).\n'
