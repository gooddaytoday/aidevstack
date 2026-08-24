#!/bin/sh
# Opt-in live verification against PID 1. Regular CI intentionally skips it.
set -eu

if [ "${ZED_SANDBOX_PRIVILEGED_TEST:-0}" != "1" ]; then
	printf 'SKIP: set ZED_SANDBOX_PRIVILEGED_TEST=1 to run the live systemd cgroup-BPF probe\n'
	exit 0
fi

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/scripts/zed-sandbox-launcher.py"
uid=$(id -u)
gid=$(id -g)
unit="zed-secure-live-test-${uid}-$$"
systemd_run=$(command -v systemd-run) || {
	printf 'FAIL: systemd-run is required\n' >&2
	exit 1
}
python=$(command -v python3) || {
	printf 'FAIL: python3 is required\n' >&2
	exit 1
}

set -- "$systemd_run" --system --quiet --wait --pipe --collect \
	--service-type=exec \
	--unit="$unit" \
	--uid="$uid" \
	--gid="$gid" \
	--working-directory="$(pwd -P)" \
	--property=KillMode=control-group \
	--property=IPAddressDeny=any \
	--property=IPAddressAllow=localhost \
	-- "$python" "$HELPER" probe --expected-unit="${unit}.service"

if [ "$uid" -eq 0 ]; then
	"$@"
else
	sudo -- "$@"
fi
printf 'OK: live system-manager cgroup-BPF sandbox verified\n'
