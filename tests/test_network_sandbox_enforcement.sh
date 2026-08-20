#!/bin/sh
# Root-backed network sandbox must verify actual enforcement and fail closed.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
INSTALLER_SOURCE="$ROOT/scripts/install-zed-secure.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT INT HUP TERM

make_instrumented_installer() {
	fixture=$1
	backend_bin=$2
	mkdir -p "$fixture"
	cat >"$backend_bin/python3" <<'EOF'
#!/bin/sh
exec /usr/bin/python3 "$@"
EOF
	chmod 700 "$backend_bin/python3"
	sed \
		-e "s|/usr/bin/systemd-run|$backend_bin/systemd-run|g" \
		-e "s|/usr/bin/sudo|$backend_bin/sudo|g" \
		-e "s|/usr/bin/python3|$backend_bin/python3|g" \
		-e 's/required_owner=0/required_owner=$(id -u)/' \
		-e 's/skip_parent_validation=0/skip_parent_validation=1/' \
		"$INSTALLER_SOURCE" >"$fixture/install-zed-secure.sh"
	cp "$ROOT/scripts/zed-security-settings.sh" "$fixture/zed-security-settings.sh"
	sed \
		-e "s|/usr/bin/systemd-run|$backend_bin/systemd-run|g" \
		-e "s|/usr/bin/sudo|$backend_bin/sudo|g" \
		-e "s|/usr/bin/python3|$backend_bin/python3|g" \
		-e 's/metadata.st_uid != 0/metadata.st_uid != os.getuid()/' \
		-e 's/if trusted_parents:/if True:/' \
		"$ROOT/scripts/zed-sandbox-launcher.py" >"$fixture/zed-sandbox-launcher.py"
	chmod +x "$fixture/install-zed-secure.sh" "$fixture/zed-security-settings.sh" \
		"$fixture/zed-sandbox-launcher.py"
	printf '%s\n' "$fixture/install-zed-secure.sh"
}

test_home="$test_root/home"
fake_bin="$test_root/bin"
install_trace="$test_root/install.trace"
mkdir -p "$test_home/.local/zed.app/bin" "$test_home/.config" \
	"$test_home/.local/share" "$fake_bin"

cat >"$test_home/.local/zed.app/bin/zed" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$test_home/.local/zed.app/bin/zed"

# Simulate the exact failure mode: the manager accepts every property but runs
# the payload outside any filtered cgroup.
cat >"$fake_bin/systemd-run" <<'EOF'
#!/bin/sh
for argument do
	printf 'ARG=%s\n' "$argument"
done >>"$SANDBOX_TRACE"
while [ "$#" -gt 0 ]; do
	case "$1" in
	-p | --property)
		shift 2
		;;
	--)
		shift
		break
		;;
	--*)
		shift
		;;
	*)
		break
		;;
	esac
done
[ "$#" -gt 0 ] || exit 0
exec "$@"
EOF
chmod 700 "$fake_bin/systemd-run"

cat >"$fake_bin/sudo" <<'EOF'
#!/bin/sh
[ "${1:-}" != "-A" ] || shift
[ "${1:-}" != "--" ] || shift
exec "$@"
EOF
chmod 700 "$fake_bin/sudo"
INSTALLER=$(make_instrumented_installer "$test_root/probe-scripts" "$fake_bin")

probe_output=""
if probe_output=$(HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
	XDG_DATA_HOME="$test_home/.local/share" \
	SANDBOX_TRACE="$install_trace" \
	PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
	"$INSTALLER" --disable-ai --enable-network-sandbox 2>&1); then
	fail 'installer accepted a backend that ignored the network filter'
fi

[ ! -e "$test_home/.local/bin/zed-secure" ] \
	|| fail 'installer wrote zed-secure after sandbox verification failed'
printf 'OK: ignored systemd IP properties fail closed before wrapper creation\n'

grep -Fx 'ARG=--system' "$install_trace" >/dev/null 2>&1 \
	|| fail "installer probe did not target the system manager: $probe_output"
if grep -Fx 'ARG=--user' "$install_trace" >/dev/null \
	|| grep -Fx 'ARG=--scope' "$install_trace" >/dev/null; then
	fail 'installer probe used the ineffective user-scope backend'
fi
printf 'OK: installer probe targets only the system manager\n'

allow_marker="$test_root/allow-no-sandbox-zed-started"
cat >"$test_home/.local/zed.app/bin/zed" <<EOF
#!/bin/sh
: >"$allow_marker"
exit 0
EOF
chmod +x "$test_home/.local/zed.app/bin/zed"
allow_output=$(HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
	XDG_DATA_HOME="$test_home/.local/share" SANDBOX_TRACE="$install_trace" \
	PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
	"$INSTALLER" --disable-ai --enable-network-sandbox --allow-no-sandbox 2>&1) \
	|| fail '--allow-no-sandbox did not permit explicit degradation'
case "$allow_output" in
*'Sandbox:    disabled'*) ;;
*) fail '--allow-no-sandbox did not report the sandbox as disabled' ;;
esac
HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" \
	XDG_DATA_HOME="$test_home/.local/share" PATH="$fake_bin:/usr/bin:/bin" \
	ZED_SECURE_NETWORK_SANDBOX=1 "$test_home/.local/bin/zed-secure" --version \
	>/dev/null 2>&1 || fail 'explicitly degraded wrapper did not launch Zed directly'
[ -e "$allow_marker" ] || fail 'explicitly degraded wrapper did not start Zed'
printf 'OK: --allow-no-sandbox is an explicit, reported degradation path\n'

runtime_home="$test_root/runtime-home"
runtime_bin="$test_root/runtime-bin"
runtime_marker="$test_root/zed-started"
runtime_trace="$test_root/runtime.trace"
hostile_bin="$test_root/hostile-bin"
hostile_python_marker="$test_root/hostile-python-started"
mkdir -p "$runtime_home/.local/zed.app/bin" "$runtime_home/.config" \
	"$runtime_home/.local/share" "$runtime_bin" "$hostile_bin"

cat >"$hostile_bin/python3" <<EOF
#!/bin/sh
: >"$hostile_python_marker"
exec "$runtime_home/.local/zed.app/bin/zed" "\$@"
EOF
chmod 700 "$hostile_bin/python3"

cat >"$runtime_home/.local/zed.app/bin/zed" <<EOF
#!/bin/sh
: >"$runtime_marker"
exit 0
EOF
chmod +x "$runtime_home/.local/zed.app/bin/zed"

# Let installation model a successful privileged probe. At launch, model a
# manager that ignores the properties and executes the in-service payload in
# the caller's ordinary cgroup.
cat >"$runtime_bin/systemd-run" <<'EOF'
#!/bin/sh
for argument do
	printf 'ARG=%s\n' "$argument"
done >>"$SANDBOX_TRACE"
case " $* " in
*"/zed-sandbox-launcher.py probe "*) exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
	case "$1" in
	-p | --property)
		shift 2
		;;
	--)
		shift
		break
		;;
	--*)
		shift
		;;
	*)
		break
		;;
	esac
done
[ "$#" -gt 0 ] || exit 0
exec "$@"
EOF
chmod 700 "$runtime_bin/systemd-run"
cp "$fake_bin/sudo" "$runtime_bin/sudo"
RUNTIME_INSTALLER=$(make_instrumented_installer "$test_root/runtime-scripts" "$runtime_bin")

runtime_path="$runtime_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
HOME="$runtime_home" XDG_CONFIG_HOME="$runtime_home/.config" \
	XDG_DATA_HOME="$runtime_home/.local/share" PATH="$runtime_path" \
	SANDBOX_TRACE="$runtime_trace" \
	"$RUNTIME_INSTALLER" --disable-ai --enable-network-sandbox >/dev/null 2>&1 \
	|| fail 'install with modeled successful privileged probe failed'

runtime_wrapper="$runtime_home/.local/bin/zed-secure"
[ -x "$runtime_wrapper" ] || fail 'sandboxed wrapper was not installed'
if HOME="$runtime_home" XDG_CONFIG_HOME="$runtime_home/.config" \
	XDG_DATA_HOME="$runtime_home/.local/share" PATH="$hostile_bin:$runtime_path" \
	SANDBOX_TRACE="$runtime_trace" SUDO_ASKPASS=/bin/true \
	ZED_SECURE_NETWORK_SANDBOX=0 \
	"$runtime_wrapper" --version \
	>/dev/null 2>&1; then
	fail 'wrapper accepted an unfiltered runtime service or environment opt-out'
fi
[ ! -e "$runtime_marker" ] || fail 'wrapper started Zed after runtime verification failed'
[ ! -e "$hostile_python_marker" ] \
	|| fail 'wrapper executed a caller-controlled python3 from PATH'
printf 'OK: runtime verification failure never starts Zed\n'

grep -Fx 'ARG=--system' "$runtime_trace" >/dev/null \
	|| fail 'runtime launcher did not target the system manager'
if grep -Fx 'ARG=--user' "$runtime_trace" >/dev/null \
	|| grep -Fx 'ARG=--scope' "$runtime_trace" >/dev/null; then
	fail 'runtime launcher used the ineffective user-scope backend'
fi
grep -Fx 'ARG=--property=IPAddressDeny=any' "$runtime_trace" >/dev/null \
	|| fail 'runtime launcher omitted IPAddressDeny=any'
grep -Fx 'ARG=--property=IPAddressAllow=localhost' "$runtime_trace" >/dev/null \
	|| fail 'runtime launcher omitted the localhost allowlist'
grep -Fx 'ARG=--property=KillMode=control-group' "$runtime_trace" >/dev/null \
	|| fail 'runtime launcher omitted child-process cgroup lifetime enforcement'
if grep -Fx 'ARG=--property=ExitType=cgroup' "$runtime_trace" >/dev/null; then
	fail 'runtime launcher requires systemd 250-only ExitType=cgroup'
fi
printf 'OK: runtime launcher uses the filtered system-service backend\n'

printf 'All network sandbox enforcement tests passed.\n'
