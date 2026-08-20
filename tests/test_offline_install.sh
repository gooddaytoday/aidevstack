#!/bin/sh
# R9: offline install via ZED_BUNDLE_PATH without network fetch
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_not_contains() {
	label=$1
	needle=$2
	haystack=$3
	if printf '%s\n' "$haystack" | grep -q "$needle"; then
		fail "$label: output must not contain '$needle'"
	fi
}

assert_contains() {
	label=$1
	needle=$2
	haystack=$3
	if ! printf '%s\n' "$haystack" | grep -q "$needle"; then
		fail "$label: expected output to contain '$needle'"
	fi
}

out=$(ZED_BUNDLE_PATH=/tmp/fake-zed-linux-x86_64.tar.gz \
	"$INSTALLER" --disable-ai --offline --dry-run 2>&1) \
	|| fail 'offline dry-run with ZED_BUNDLE_PATH failed'

assert_not_contains 'no curl to install.sh' \
	'curl -f https://zed.dev/install.sh' "$out"
assert_not_contains 'no curl to install.sh' \
	'curl -f https://zed.dev/install.sh | sh' "$out"
assert_contains 'local bundle message' 'Installing Zed from local bundle' "$out"
assert_contains 'staged extract' 'extract bundle into a staging directory' "$out"
assert_contains 'zed symlink' 'ln -sf' "$out"
printf 'OK: ZED_BUNDLE_PATH dry-run uses local install without curl\n'

out=$("$INSTALLER" --disable-ai --offline --dry-run 2>&1) && \
	fail '--offline without bundle should exit non-zero'
case "$out" in
*ZED_BUNDLE_PATH*) ;;
*) fail "expected ZED_BUNDLE_PATH error, got: $out" ;;
esac
printf 'OK: --offline without bundle rejected\n'

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT INT HUP TERM
test_home="$test_root/home"
mkdir -p "$test_home/.local/zed.app" "$test_root/config" "$test_root/data"
printf 'keep-old-install\n' >"$test_home/.local/zed.app/old-marker"
printf 'not a tar archive\n' >"$test_root/corrupt.tar.gz"

if HOME=$test_home XDG_CONFIG_HOME="$test_root/config" XDG_DATA_HOME="$test_root/data" \
	ZED_BUNDLE_PATH="$test_root/corrupt.tar.gz" \
	"$INSTALLER" --disable-ai --offline >/dev/null 2>&1; then
	fail 'corrupt offline bundle should fail'
fi
[ -f "$test_home/.local/zed.app/old-marker" ] \
	|| fail 'corrupt bundle removed the existing app directory'
if find "$test_home/.local" -maxdepth 1 -name '.zed-secure-stage.*' -print -quit | grep -q .; then
	fail 'corrupt bundle left a staging directory behind'
fi
printf 'OK: corrupt bundle preserves the existing app directory\n'

bundle_root="$test_root/bundle-root"
mkdir -p "$bundle_root/zed.app/bin"
printf '#!/bin/sh\nexit 0\n' >"$bundle_root/zed.app/bin/zed"
chmod +x "$bundle_root/zed.app/bin/zed"
tar -czf "$test_root/valid.tar.gz" -C "$bundle_root" zed.app

HOME=$test_home XDG_CONFIG_HOME="$test_root/config" XDG_DATA_HOME="$test_root/data" \
	ZED_BUNDLE_PATH="$test_root/valid.tar.gz" \
	"$INSTALLER" --disable-ai --offline >/dev/null 2>&1 \
	|| fail 'valid staged offline install failed'
[ -x "$test_home/.local/zed.app/bin/zed" ] || fail 'staged app was not activated'
[ ! -e "$test_home/.local/zed.app/old-marker" ] || fail 'old app directory survived successful swap'
printf 'OK: valid bundle atomically replaces the app directory\n'

printf 'All offline install tests passed.\n'
