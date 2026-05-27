#!/bin/sh
# R13: agent.tool_permissions always written, including --disable-ai
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

if ! command -v jq >/dev/null 2>&1; then
	printf 'SKIP: jq required for agent permissions tests\n'
	exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
mkdir -p "$tmp/zed"

XDG_CONFIG_HOME=$tmp "$INSTALLER" --disable-ai >/dev/null 2>&1 \
	|| fail '--disable-ai install failed'

if ! jq empty "$tmp/zed/settings.json" 2>/dev/null; then
	fail 'settings.json is not valid JSON'
fi
printf 'OK: settings.json valid JSON\n'

disable_ai=$(jq -r '.disable_ai' "$tmp/zed/settings.json")
[ "$disable_ai" = "true" ] || fail "expected disable_ai=true, got $disable_ai"
printf 'OK: disable_ai=true\n'

fetch_default=$(jq -r '.agent.tool_permissions.tools.fetch.default' "$tmp/zed/settings.json")
[ "$fetch_default" = "deny" ] || fail "expected fetch.default=deny, got $fetch_default"

search_default=$(jq -r '.agent.tool_permissions.tools.search_web.default' "$tmp/zed/settings.json")
[ "$search_default" = "deny" ] || fail "expected search_web.default=deny, got $search_default"
printf 'OK: agent fetch/search_web denied with --disable-ai\n'

# merge-config: permissive agent in old file must be overwritten
cat >"$tmp/zed/settings.json" <<'EOF'
{
  "custom_key": true,
  "agent": {
    "tool_permissions": {
      "default": "allow",
      "tools": {
        "fetch": { "default": "allow" },
        "search_web": { "default": "allow" }
      }
    }
  }
}
EOF

XDG_CONFIG_HOME=$tmp "$INSTALLER" --disable-ai --merge-config >/dev/null 2>&1 \
	|| fail 'merge-config with --disable-ai failed'

fetch_merged=$(jq -r '.agent.tool_permissions.tools.fetch.default' "$tmp/zed/settings.json")
[ "$fetch_merged" = "deny" ] || fail "merge: expected fetch.default=deny, got $fetch_merged"

custom=$(jq -r '.custom_key' "$tmp/zed/settings.json")
[ "$custom" = "true" ] || fail "merge: expected custom_key preserved, got $custom"
printf 'OK: merge-config overwrites permissive agent permissions\n'

printf 'All agent permissions disable-ai tests passed.\n'
