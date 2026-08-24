#!/bin/sh
# Security overlay, repair-settings, enforce helper, wrapper embed
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"
ENFORCE="$ROOT/scripts/zed-security-settings.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

if ! command -v jq >/dev/null 2>&1; then
	printf 'SKIP: jq required for security enforce tests\n'
	exit 0
fi

sh -n "$ENFORCE" || fail 'syntax check zed-security-settings.sh'
# shellcheck source=/dev/null
. "$ENFORCE"

# Security-only overlay preserves custom keys
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
profile="$tmp/profile"
mkdir -p "$tmp/zed" "$profile/.local/zed.app/bin"
printf '#!/bin/sh\nexit 0\n' >"$profile/.local/zed.app/bin/zed"
chmod +x "$profile/.local/zed.app/bin/zed"

cat >"$tmp/zed/settings.json" <<'EOF'
{
  "custom_theme": "keep-me",
  "telemetry": { "metrics": true, "diagnostics": true },
  "language_models": { "openai_compatible": { "GPUStack": { "api_url": "http://gpu.local/v1" } } }
}
EOF

HOME=$profile XDG_CONFIG_HOME=$tmp XDG_DATA_HOME="$profile/.local/share" \
	"$INSTALLER" --disable-ai >/dev/null 2>&1 \
	|| fail 'install with existing settings failed'

metrics=$(jq -r '.telemetry.metrics' "$tmp/zed/settings.json")
theme=$(jq -r '.custom_theme' "$tmp/zed/settings.json")
api_url=$(jq -r '.language_models.openai_compatible.GPUStack.api_url' "$tmp/zed/settings.json")

[ "$metrics" = "false" ] || fail "expected telemetry.metrics=false, got $metrics"
[ "$theme" = "keep-me" ] || fail "custom_theme should be preserved, got $theme"
[ "$api_url" = "http://gpu.local/v1" ] || fail "language_models should be preserved, got $api_url"
[ -f "$tmp/zed/settings.zed-secure-template.json" ] || fail 'template file missing'
printf 'OK: security-only overlay preserves user keys\n'

# --repair-settings fixes bad telemetry using saved template from prior install
cat >"$tmp/zed/settings.json" <<'EOF'
{
  "telemetry": { "metrics": true, "diagnostics": true },
  "auto_update": true
}
EOF
HOME=$profile XDG_CONFIG_HOME=$tmp XDG_DATA_HOME="$profile/.local/share" \
	"$INSTALLER" --repair-settings >/dev/null 2>&1 \
	|| fail '--repair-settings on corrupted settings failed'

metrics=$(jq -r '.telemetry.metrics' "$tmp/zed/settings.json")
[ "$metrics" = "false" ] || fail "repair: expected telemetry.metrics=false, got $metrics"
printf 'OK: --repair-settings restores privacy keys\n'

# sed fallback on JSONC-like trailing comma
jsonc="$tmp/jsonc-settings.json"
mkdir -p "$(dirname "$jsonc")"
cat >"$jsonc" <<'EOF'
{
  "telemetry": { "diagnostics": true, "metrics": true, },
}
EOF
cp "$tmp/zed/settings.zed-secure-template.json" "$tmp/template.json"
if telemetry_sed_fallback "$jsonc"; then
	grep -q '"metrics": false' "$jsonc" || fail 'sed fallback should set metrics false'
	printf 'OK: telemetry sed fallback on JSONC\n'
else
	fail 'telemetry sed fallback failed'
fi

# jq overlay after JSONC normalize (Zed-style trailing commas)
jsonc2="$tmp/zed/jsonc-full.json"
cat >"$jsonc2" <<'EOF'
{
  "terminal": { "font_size": 16.0, },
  "custom_theme": "keep-jsonc",
  "telemetry": { "diagnostics": true, "metrics": true },
}
EOF
ZED_ENFORCE_DRY_RUN=0 enforce_security_settings "$jsonc2" "$tmp/zed/settings.zed-secure-template.json" \
	|| fail 'enforce on JSONC settings failed'
metrics=$(jq -r '.telemetry.metrics' "$jsonc2")
theme=$(jq -r '.custom_theme' "$jsonc2")
[ "$metrics" = "false" ] || fail "JSONC enforce: expected metrics false, got $metrics"
[ "$theme" = "keep-jsonc" ] || fail "JSONC enforce: custom_theme lost, got $theme"
printf 'OK: JSONC normalize + security overlay\n'

# Share template when config template path is missing
share_tpl="$tmp/share-zed-secure/settings-template.json"
mkdir -p "$(dirname "$share_tpl")"
cp "$tmp/zed/settings.zed-secure-template.json" "$share_tpl"
jsonc3="$tmp/zed/no-config-template.json"
cat >"$jsonc3" <<'EOF'
{ "telemetry": { "diagnostics": true, "metrics": true } }
EOF
ZED_SECURE_TEMPLATE_SHARE="$share_tpl" enforce_security_settings "$jsonc3" "/nonexistent/template.json" \
	|| fail 'enforce with share template only failed'
metrics=$(jq -r '.telemetry.metrics' "$jsonc3")
[ "$metrics" = "false" ] || fail "share template: expected metrics false, got $metrics"
printf 'OK: enforce uses share-dir template backup\n'

# Wrapper contains enforce hook (isolated HOME; preinstall Zed to skip network)
home=$(mktemp -d)
trap 'rm -rf "$tmp" "$home"' EXIT INT HUP TERM
mkdir -p "$home/.config/zed" "$home/.local/zed.app/bin"
printf '#!/bin/sh\n[ -z "${ZED_TEST_ENV_CAPTURE:-}" ] || env >"$ZED_TEST_ENV_CAPTURE"\nexit 0\n' \
	>"$home/.local/zed.app/bin/zed"
chmod +x "$home/.local/zed.app/bin/zed"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
	HOME=$home XDG_CONFIG_HOME="$home/.config" "$INSTALLER" --disable-ai >/dev/null 2>&1 \
	|| fail 'install for wrapper check failed'
wrapper="$home/.local/bin/zed-secure"
enforce_installed="$home/.local/share/zed-secure/enforce-settings.sh"
[ -f "$wrapper" ] || fail 'zed-secure wrapper missing'
grep -q 'enforce-settings.sh' "$wrapper" || fail 'wrapper missing enforce-settings.sh call'
grep -q 'ZED_SECURE_ENFORCE_SETTINGS' "$wrapper" || fail 'wrapper missing enforce opt-out'
[ -x "$enforce_installed" ] || fail 'enforce-settings.sh not installed'
printf 'OK: zed-secure wrapper embeds privacy enforce\n'

# Wrapper E2E: launch runs enforce and fixes telemetry
cat >"$home/.config/zed/settings.json" <<'EOF'
{
  "telemetry": { "metrics": true, "diagnostics": true },
  "auto_update": true
}
EOF
env_capture="$home/zed-env.txt"
OPENAI_API_KEY=secret ANTHROPIC_API_KEY=secret GOOGLE_API_KEY=secret \
	GOOGLE_AI_API_KEY=secret GEMINI_API_KEY=secret MISTRAL_API_KEY=secret \
	DEEPSEEK_API_KEY=secret XAI_API_KEY=secret OPENCODE_API_KEY=secret \
	OPENROUTER_API_KEY=secret VERCEL_AI_GATEWAY_API_KEY=secret \
	OLLAMA_API_KEY=secret LMSTUDIO_API_KEY=secret TOGETHER_AI_API_KEY=secret \
	ZED_TEST_ENV_CAPTURE="$env_capture" \
	PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
	HOME=$home XDG_CONFIG_HOME="$home/.config" \
	"$wrapper" --version >/dev/null 2>&1 || fail 'wrapper launch failed'
metrics=$(jq -r '.telemetry.metrics' "$home/.config/zed/settings.json")
[ "$metrics" = "false" ] || fail "wrapper E2E: expected metrics false after launch, got $metrics"
printf 'OK: zed-secure launch enforces telemetry off\n'

for key in OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY GOOGLE_AI_API_KEY \
	GEMINI_API_KEY MISTRAL_API_KEY DEEPSEEK_API_KEY XAI_API_KEY OPENCODE_API_KEY \
	OPENROUTER_API_KEY VERCEL_AI_GATEWAY_API_KEY OLLAMA_API_KEY LMSTUDIO_API_KEY \
	TOGETHER_AI_API_KEY; do
	if grep -q "^${key}=" "$env_capture"; then
		fail "wrapper leaked provider credential: $key"
	fi
done
printf 'OK: zed-secure wrapper clears documented provider API keys\n'

printf 'All security enforce tests passed.\n'
