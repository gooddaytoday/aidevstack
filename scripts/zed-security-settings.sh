#!/bin/sh
# zed-security-settings.sh — Apply/verify Zed privacy settings overlay
# POSIX sh. Used by install-zed-secure.sh, zed-secure wrapper, and --repair-settings.

set -eu

warn_msg() {
	printf 'WARNING: %s\n' "$*" >&2
}

# Share-dir copy survives missing ~/.config/zed/settings.zed-secure-template.json
ZED_SECURE_TEMPLATE_SHARE="${ZED_SECURE_TEMPLATE_SHARE:-$HOME/.local/share/zed-secure/settings-template.json}"

resolve_security_template() {
	primary=$1
	share_tpl="${ZED_SECURE_TEMPLATE_SHARE:-$HOME/.local/share/zed-secure/settings-template.json}"
	if [ -n "$primary" ] && [ -f "$primary" ]; then
		printf '%s' "$primary"
		return 0
	fi
	if [ -f "$share_tpl" ]; then
		printf '%s' "$share_tpl"
		return 0
	fi
	return 1
}

# Security-only overlay: preserve user keys (language_models, editor, etc.)
security_overlay_merge() {
	existing=$1
	template=$2
	jq -s '
		.[0] as $old | .[1] as $new |
		($old * $new) |
		.auto_update = $new.auto_update |
		.disable_ai = $new.disable_ai |
		.telemetry = $new.telemetry |
		.title_bar = $new.title_bar |
		(if $new.session then .session = $new.session else . end) |
		(if $new.collaboration_panel then .collaboration_panel = $new.collaboration_panel else . end) |
		(if $new.file_scan_exclusions then .file_scan_exclusions = $new.file_scan_exclusions else . end) |
		.agent = $new.agent |
		(if $new.edit_predictions then .edit_predictions = $new.edit_predictions else . end) |
		(if $new.show_edit_predictions != null then .show_edit_predictions = $new.show_edit_predictions else . end)
	' "$existing" "$template"
}

# Full merge including language_models (--merge-config / --refresh-llm-config)
full_overlay_merge() {
	existing=$1
	template=$2
	jq -s '
		.[0] as $old | .[1] as $new |
		($old * $new) |
		.auto_update = $new.auto_update |
		.disable_ai = $new.disable_ai |
		.telemetry = $new.telemetry |
		.title_bar = $new.title_bar |
		(if $new.session then .session = $new.session else . end) |
		(if $new.collaboration_panel then .collaboration_panel = $new.collaboration_panel else . end) |
		(if $new.file_scan_exclusions then .file_scan_exclusions = $new.file_scan_exclusions else . end) |
		.agent = $new.agent |
		(if $new.edit_predictions then .edit_predictions = $new.edit_predictions else . end) |
		(if $new.show_edit_predictions != null then .show_edit_predictions = $new.show_edit_predictions else . end) |
		(if $new.language_models then .language_models = $new.language_models else . end)
	' "$existing" "$template"
}

# Strip trailing commas (Zed JSONC) until jq accepts the file or we give up
jsonc_normalize_file() {
	src=$1
	dest=$2
	if [ ! -f "$src" ]; then
		return 1
	fi
	if zed_settings_jq_parseable "$src"; then
		cp "$src" "$dest"
		return 0
	fi
	if command -v python3 >/dev/null 2>&1; then
		if python3 - "$src" "$dest" <<'PY'
import json, re, sys

src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
for _ in range(50):
    prev = text
    # comma before } or ] (same line or next line)
    text = re.sub(r",(\s*[\}\]])", r"\1", text)
    text = re.sub(r",(\s*\n\s*[\}\]])", r"\1", text)
    if text == prev:
        break
json.loads(text)
open(dest, "w", encoding="utf-8").write(text)
PY
		then
			return 0
		fi
	fi
	if ! command -v sed >/dev/null 2>&1; then
		return 1
	fi
	cp "$src" "$dest"
	i=0
	while [ "$i" -lt 20 ]; do
		if command -v jq >/dev/null 2>&1 && jq empty "$dest" 2>/dev/null; then
			return 0
		fi
		next=$(mktemp)
		sed -E 's/,[[:space:]]*(\}|\])/\1/g' "$dest" >"$next" || {
			rm -f "$next"
			return 1
		}
		mv "$next" "$dest"
		i=$((i + 1))
	done
	command -v jq >/dev/null 2>&1 && jq empty "$dest" 2>/dev/null
}

privacy_sed_fallback() {
	settings=$1
	if [ ! -f "$settings" ]; then
		return 1
	fi
	if ! command -v sed >/dev/null 2>&1; then
		return 1
	fi
	sed -i \
		-e 's/"diagnostics"[[:space:]]*:[[:space:]]*true/"diagnostics": false/g' \
		-e 's/"metrics"[[:space:]]*:[[:space:]]*true/"metrics": false/g' \
		-e 's/"auto_update"[[:space:]]*:[[:space:]]*true/"auto_update": false/g' \
		-e 's/"trust_all_worktrees"[[:space:]]*:[[:space:]]*true/"trust_all_worktrees": false/g' \
		"$settings" 2>/dev/null || return 1
	return 0
}

# Legacy name used in tests
telemetry_sed_fallback() {
	privacy_sed_fallback "$1"
}

# Returns 0 if settings file parses as JSON
zed_settings_jq_parseable() {
	path=$1
	[ -f "$path" ] && command -v jq >/dev/null 2>&1 && jq empty "$path" 2>/dev/null
}

# Infer DISABLE_AI / LLM vars from settings.json for safe template regeneration.
# Sets shell variables in the caller (sourced). Returns 0 on success, 1 if unreadable.
apply_inferred_install_flags() {
	settings_path=$1
	work=$settings_path
	norm_tmp=""

	if [ ! -f "$settings_path" ]; then
		return 1
	fi

	if ! zed_settings_jq_parseable "$settings_path"; then
		norm_tmp=$(mktemp)
		if jsonc_normalize_file "$settings_path" "$norm_tmp"; then
			work=$norm_tmp
		else
			rm -f "$norm_tmp"
			if grep -q '"disable_ai"[[:space:]]*:[[:space:]]*true' "$settings_path" 2>/dev/null; then
				DISABLE_AI=1
				return 0
			fi
			if grep -q 'openai_compatible' "$settings_path" 2>/dev/null; then
				DISABLE_AI=0
				return 0
			fi
			return 1
		fi
	fi

	if ! command -v jq >/dev/null 2>&1; then
		[ -n "$norm_tmp" ] && rm -f "$norm_tmp"
		return 1
	fi

	if jq -e '.disable_ai == true' "$work" >/dev/null 2>&1; then
		DISABLE_AI=1
		[ -n "$norm_tmp" ] && rm -f "$norm_tmp"
		return 0
	fi

	if jq -e '.language_models.openai_compatible != null and (.language_models.openai_compatible | length) > 0' \
		"$work" >/dev/null 2>&1; then
		DISABLE_AI=0
		provider=$(jq -r '.language_models.openai_compatible | keys[0]' "$work")
		if [ -n "$provider" ] && [ "$provider" != "null" ]; then
			ZED_LLM_PROVIDER_NAME=$provider
			api=$(jq -r --arg p "$provider" \
				'.language_models.openai_compatible[$p].api_url // empty' "$work")
			[ -n "$api" ] && ZED_LLM_API_URL=$api
			model=$(jq -r --arg p "$provider" \
				'.language_models.openai_compatible[$p].available_models[0].name // empty' "$work")
			[ -n "$model" ] && ZED_LLM_MODEL=$model
		fi
		[ -n "$norm_tmp" ] && rm -f "$norm_tmp"
		return 0
	fi

	[ -n "$norm_tmp" ] && rm -f "$norm_tmp"
	return 1
}

# enforce_security_settings SETTINGS TEMPLATE_PATH
# DRY_RUN and REFRESH_LLM passed via env for POSIX sh portability
# Exit: 0 = full jq overlay, 2 = partial sed-only, 1 = failure
enforce_security_settings() {
	settings=$1
	template_arg=$2
	dry_run=${ZED_ENFORCE_DRY_RUN:-0}
	refresh_llm=${ZED_ENFORCE_REFRESH_LLM:-0}
	norm_tmp=""

	template=""
	if template=$(resolve_security_template "$template_arg" 2>/dev/null); then
		:
	else
		warn_msg "Security template missing (config and ${ZED_SECURE_TEMPLATE_SHARE:-$HOME/.local/share/zed-secure/settings-template.json})"
		if [ ! -f "$settings" ]; then
			return 1
		fi
		if [ "$dry_run" -eq 1 ]; then
			printf '[dry-run] would run privacy sed fallback on %s (no template)\n' "$settings"
			return 0
		fi
		if privacy_sed_fallback "$settings"; then
			warn_msg "Partial fix (sed only). Re-run install-zed-secure.sh to regenerate template."
			return 2
		fi
		return 1
	fi

	if [ ! -f "$settings" ]; then
		if [ "$dry_run" -eq 1 ]; then
			printf '[dry-run] would create %s from template\n' "$settings"
			return 0
		fi
		mkdir -p "$(dirname "$settings")"
		cp "$template" "$settings"
		return 0
	fi

	work_settings=$settings
	if ! zed_settings_jq_parseable "$settings"; then
		norm_tmp=$(mktemp)
		if jsonc_normalize_file "$settings" "$norm_tmp"; then
			work_settings=$norm_tmp
		fi
	fi

	if zed_settings_jq_parseable "$work_settings"; then
		if [ "$dry_run" -eq 1 ]; then
			printf '[dry-run] would apply security overlay to %s\n' "$settings"
			[ -n "$norm_tmp" ] && rm -f "$norm_tmp"
			return 0
		fi
		out=$(mktemp)
		if [ "$refresh_llm" -eq 1 ]; then
			full_overlay_merge "$work_settings" "$template" >"$out"
		else
			security_overlay_merge "$work_settings" "$template" >"$out"
		fi
		mv "$out" "$settings"
		[ -n "$norm_tmp" ] && rm -f "$norm_tmp"
		return 0
	fi

	[ -n "$norm_tmp" ] && rm -f "$norm_tmp"
	warn_msg "settings.json is not valid JSON (Zed JSONC?). Trying privacy sed fallback."
	if [ "$dry_run" -eq 1 ]; then
		printf '[dry-run] would run privacy sed fallback on %s\n' "$settings"
		return 0
	fi
	if privacy_sed_fallback "$settings"; then
		warn_msg "Partial fix applied (sed). Close Zed and run: install-zed-secure.sh --repair-settings"
		return 2
	fi
	warn_msg "Could not enforce settings. Close Zed and run: install-zed-secure.sh --repair-settings"
	return 1
}

# verify_security_settings SETTINGS — returns 0 if OK, 1 if violations
verify_security_settings() {
	settings_path=$1
	check_tmp=""

	if zed_settings_jq_parseable "$settings_path"; then
		check_tmp=$settings_path
	elif command -v jq >/dev/null 2>&1; then
		check_tmp=$(mktemp)
		if jsonc_normalize_file "$settings_path" "$check_tmp"; then
			:
		else
			rm -f "$check_tmp"
			check_tmp=""
		fi
	fi

	if [ -n "$check_tmp" ] && zed_settings_jq_parseable "$check_tmp"; then
		ok=0
		if ! jq -e '.telemetry.metrics == false' "$check_tmp" >/dev/null 2>&1; then
			warn_msg "telemetry.metrics is not false"
			ok=1
		fi
		if ! jq -e '.telemetry.diagnostics == false' "$check_tmp" >/dev/null 2>&1; then
			warn_msg "telemetry.diagnostics is not false"
			ok=1
		fi
		if ! jq -e '.auto_update == false' "$check_tmp" >/dev/null 2>&1; then
			warn_msg "auto_update is not false"
			ok=1
		fi
		[ "$check_tmp" != "$settings_path" ] && rm -f "$check_tmp"
		return "$ok"
	fi

	ok=0
	if ! grep -q '"metrics"[[:space:]]*:[[:space:]]*false' "$settings_path" 2>/dev/null; then
		warn_msg "telemetry.metrics is not false (JSONC; grep check)"
		ok=1
	fi
	if ! grep -q '"diagnostics"[[:space:]]*:[[:space:]]*false' "$settings_path" 2>/dev/null; then
		warn_msg "telemetry.diagnostics is not false (JSONC; grep check)"
		ok=1
	fi
	return "$ok"
}

# Direct invocation: sh enforce-settings.sh SETTINGS TEMPLATE (not when sourced)
case "$0" in
*/enforce-settings.sh | */zed-security-settings.sh)
	if [ -f "${1:-}" ]; then
		enforce_security_settings "$1" "${2:-}"
		enforce_rc=$?
		if [ "$enforce_rc" -eq 1 ]; then
			exit 1
		fi
		if verify_security_settings "$1"; then
			[ "$enforce_rc" -eq 2 ] && exit 2
			exit 0
		fi
		if [ "${ZED_ENFORCE_STRICT_VERIFY:-0}" = 1 ]; then
			exit 1
		fi
		[ "$enforce_rc" -eq 2 ] && exit 2
		exit 0
	fi
	;;
esac
