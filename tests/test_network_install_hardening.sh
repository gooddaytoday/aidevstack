#!/bin/sh
# Network installer must be fully downloaded and optionally verified before execution.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

real_mktemp=$(command -v mktemp) || fail 'mktemp is required'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu
[ -z "${FAKE_CURL_MARKER:-}" ] || : >"$FAKE_CURL_MARKER"
out=
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o)
		out=$2
		shift 2
		;;
	*) shift ;;
	esac
done
[ -n "$out" ] || exit 2
if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then
	printf '#!/bin/sh\n: >"$FAKE_EXEC_MARKER"\n' >"$out"
	exit 22
fi
cp "$FAKE_INSTALLER_SOURCE" "$out"
EOF
chmod +x "$fake_bin/curl"

cat >"$fake_bin/mktemp" <<'EOF'
#!/bin/sh
set -eu
[ -z "${FAKE_MKTEMP_MARKER:-}" ] || : >"$FAKE_MKTEMP_MARKER"
exec "$REAL_MKTEMP" "$@"
EOF
chmod +x "$fake_bin/mktemp"

cat >"$tmp/upstream-installer.sh" <<'EOF'
#!/bin/sh
set -eu
mkdir -p "$HOME/.local/zed.app/bin"
ln -sf /bin/true "$HOME/.local/zed.app/bin/zed"
: >"$FAKE_EXEC_MARKER"
EOF

run_installer() {
	case_name=$1
	shift
	case_root="$tmp/$case_name"
	mkdir -p "$case_root/home" "$case_root/config" "$case_root/data"
	PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
		HOME="$case_root/home" XDG_CONFIG_HOME="$case_root/config" \
		XDG_DATA_HOME="$case_root/data" FAKE_INSTALLER_SOURCE="$tmp/upstream-installer.sh" \
		FAKE_EXEC_MARKER="$case_root/executed" FAKE_CURL_MARKER="$case_root/curl-called" \
		FAKE_MKTEMP_MARKER="$case_root/mktemp-called" REAL_MKTEMP="$real_mktemp" \
		"$@"
}

short_sha=$(printf '%063d' 0)
long_sha=$(printf '%065d' 0)
non_hex_sha=$(printf '%064d' 0)
non_hex_sha=${non_hex_sha%?}g
for malformed_entry in \
	"short:$short_sha" \
	"long:$long_sha" \
	"non-hex:$non_hex_sha"
do
	malformed_name=${malformed_entry%%:*}
	malformed_sha=${malformed_entry#*:}
	if out=$(run_installer "malformed-dry-run-$malformed_name" env \
		ZED_INSTALLER_SHA256=$malformed_sha \
		"$INSTALLER" --disable-ai --dry-run 2>&1); then
		fail "$malformed_name checksum should fail during dry-run"
	fi
	case "$out" in
	*'ZED_INSTALLER_SHA256 must be exactly 64 hexadecimal characters'*) ;;
	*) fail "$malformed_name checksum dry-run did not report the validation error" ;;
	esac
done
printf 'OK: malformed checksum forms are rejected during dry-run\n'

if out=$(run_installer malformed-real env ZED_INSTALLER_SHA256=$non_hex_sha \
	"$INSTALLER" --disable-ai 2>&1); then
	fail 'malformed checksum should fail during a real install'
fi
case "$out" in
*'ZED_INSTALLER_SHA256 must be exactly 64 hexadecimal characters'*) ;;
*) fail 'malformed checksum real install did not report the validation error' ;;
esac
[ ! -e "$tmp/malformed-real/mktemp-called" ] || \
	fail 'malformed checksum created a temporary installer file'
[ ! -e "$tmp/malformed-real/curl-called" ] || \
	fail 'malformed checksum attempted a network request'
printf 'OK: malformed checksum fails before temporary-file creation or download\n'

if run_installer truncated env FAKE_CURL_FAIL=1 \
	"$INSTALLER" --disable-ai >/dev/null 2>&1; then
	fail 'truncated network download should fail'
fi
[ ! -e "$tmp/truncated/executed" ] || fail 'partial download was executed'
printf 'OK: failed download is never streamed into sh\n'

bad_sha=0000000000000000000000000000000000000000000000000000000000000000
if run_installer bad-checksum env ZED_INSTALLER_SHA256=$bad_sha \
	"$INSTALLER" --disable-ai >/dev/null 2>&1; then
	fail 'checksum mismatch should fail'
fi
[ ! -e "$tmp/bad-checksum/executed" ] || fail 'checksum-mismatched installer was executed'
printf 'OK: checksum mismatch prevents execution\n'

good_sha=$(sha256sum "$tmp/upstream-installer.sh" | awk '{print $1}')
out=$(run_installer verified env ZED_INSTALLER_SHA256=$good_sha \
	"$INSTALLER" --disable-ai 2>&1) || fail 'verified installer execution failed'
case "$out" in
*'Verified upstream installer SHA-256'*) ;;
*) fail 'verified install did not report checksum success' ;;
esac
[ -e "$tmp/verified/executed" ] || fail 'verified upstream installer did not execute'
printf 'OK: matching checksum permits execution\n'

printf 'All network installer hardening tests passed.\n'
