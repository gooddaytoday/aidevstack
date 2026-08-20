#!/usr/bin/env python3
"""Launch-time verification for the root-backed Zed network sandbox."""

from __future__ import annotations

import argparse
import errno
import fcntl
import ipaddress
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Union


SIOCGIFFLAGS = 0x8913
SIOCGIFADDR = 0x8915
IFF_UP = 0x1
IFF_LOOPBACK = 0x8
ALLOWED_CHANNELS = ("stable", "preview", "nightly", "dev")
PASSTHROUGH_ENVIRONMENT = (
    "HOME",
    "PATH",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "XAUTHORITY",
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
    "DESKTOP_SESSION",
    "LANG",
    "LANGUAGE",
    "SHELL",
    "SSH_AUTH_SOCK",
)
ZED_APP_EXECUTABLE = re.compile(
    r"(?:^|/)zed(?:-(?:preview|nightly|dev))?\.app/bin/(?:zed|cli)(?: \(deleted\))?$",
    re.IGNORECASE,
)
ZED_EXECUTABLE_NAMES = {
    "zed",
    "zeditor",
    "zed-preview",
    "zed-nightly",
    "zed-dev",
}
TRUSTED_COMMAND_CANDIDATES = {
    "python3": ("/usr/bin/python3", "/usr/local/bin/python3", "/bin/python3"),
    "sudo": ("/usr/bin/sudo", "/bin/sudo"),
    "systemctl": ("/usr/bin/systemctl", "/bin/systemctl"),
    "systemd-run": ("/usr/bin/systemd-run", "/bin/systemd-run"),
}


class SandboxError(RuntimeError):
    """The requested network boundary could not be positively verified."""


@dataclass(frozen=True)
class InterfaceAddress:
    family: int
    address: str
    interface_index: int = 0


def _interface_flags(control: socket.socket, name: str) -> int:
    request = struct.pack("256s", name.encode("utf-8")[:15])
    result = fcntl.ioctl(control.fileno(), SIOCGIFFLAGS, request)
    return struct.unpack("H", result[16:18])[0]


def discover_non_loopback_addresses() -> List[InterfaceAddress]:
    """Return one usable local address for each configured IP family."""
    found: Dict[int, InterfaceAddress] = {}
    interfaces = socket.if_nameindex()

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as control:
        for index, name in interfaces:
            try:
                flags = _interface_flags(control, name)
            except OSError:
                continue
            if not flags & IFF_UP or flags & IFF_LOOPBACK:
                continue
            if socket.AF_INET not in found:
                request = struct.pack("256s", name.encode("utf-8")[:15])
                try:
                    result = fcntl.ioctl(control.fileno(), SIOCGIFADDR, request)
                except OSError:
                    pass
                else:
                    address = socket.inet_ntoa(result[20:24])
                    if not address.startswith("127."):
                        found[socket.AF_INET] = InterfaceAddress(
                            socket.AF_INET, address, index
                        )

    interface_by_name = {name: index for index, name in interfaces}
    try:
        with open("/proc/net/if_inet6", encoding="ascii") as source:
            ipv6_rows = source.readlines()
    except OSError:
        ipv6_rows = []

    for row in ipv6_rows:
        fields = row.split()
        if len(fields) != 6 or socket.AF_INET6 in found:
            continue
        encoded, index_hex, _prefix, _scope, _flags, name = fields
        index = interface_by_name.get(name)
        if index is None:
            continue
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as control6:
                flags = _interface_flags(control6, name)
            address = socket.inet_ntop(socket.AF_INET6, bytes.fromhex(encoded))
        except (OSError, ValueError):
            continue
        if not flags & IFF_UP or flags & IFF_LOOPBACK or address == "::1":
            continue
        if int(index_hex, 16) != index:
            continue
        found[socket.AF_INET6] = InterfaceAddress(socket.AF_INET6, address, index)

    return [found[family] for family in (socket.AF_INET, socket.AF_INET6) if family in found]


def _destination(address: InterfaceAddress, port: int) -> Tuple[object, ...]:
    if address.family == socket.AF_INET6:
        return (address.address, port, 0, address.interface_index)
    return (address.address, port)


def verify_loopback(family: int) -> None:
    loopback = "::1" if family == socket.AF_INET6 else "127.0.0.1"
    with socket.socket(family, socket.SOCK_DGRAM) as receiver:
        receiver.settimeout(1.0)
        receiver.bind((loopback, 0))
        destination = receiver.getsockname()
        with socket.socket(family, socket.SOCK_DGRAM) as sender:
            sender.sendto(b"zed-secure-loopback", destination)
        payload, _peer = receiver.recvfrom(64)
    if payload != b"zed-secure-loopback":
        raise SandboxError(f"{loopback} loopback verification returned bad data")


def verify_non_loopback_denied(
    address: InterfaceAddress,
    socket_type: int,
    udp_permission_denial_proven: bool = False,
) -> None:
    protocol = "TCP" if socket_type == socket.SOCK_STREAM else "UDP"
    with socket.socket(address.family, socket_type) as receiver:
        receiver.bind(_destination(address, 0))
        if socket_type == socket.SOCK_STREAM:
            receiver.listen(1)
        port = receiver.getsockname()[1]
        with socket.socket(address.family, socket_type) as sender:
            sender.settimeout(1.0)
            try:
                if socket_type == socket.SOCK_STREAM:
                    sender.connect(_destination(address, port))
                else:
                    sender.sendto(b"zed-secure-egress", _destination(address, port))
            except socket.timeout as exc:
                # systemd's cgroup-skb program rejects UDP sendto() with EPERM,
                # but drops a TCP SYN, so connect() times out. A timeout is
                # useful only as the secondary TCP non-escape check after the
                # same-family UDP operation positively identified the filter.
                if socket_type == socket.SOCK_STREAM and udp_permission_denial_proven:
                    return
                raise SandboxError(
                    f"non-loopback {protocol} to {address.address} "
                    f"failed inconclusively: {exc}"
                ) from exc
            except OSError as exc:
                if exc.errno in (errno.EACCES, errno.EPERM):
                    return
                raise SandboxError(
                    f"non-loopback {protocol} to {address.address} "
                    f"failed inconclusively: {exc}"
                ) from exc
    raise SandboxError(
        f"non-loopback {protocol} traffic to {address.address} was not denied"
    )


def read_unified_cgroup(pid: str = "self") -> str:
    try:
        with open(f"/proc/{pid}/cgroup", encoding="ascii") as source:
            rows = source.readlines()
    except OSError as exc:
        raise SandboxError(f"cannot read cgroup membership: {exc}") from exc
    for row in rows:
        hierarchy, controllers, path = row.rstrip("\n").split(":", 2)
        if hierarchy == "0" and controllers == "":
            return path
    raise SandboxError("unified cgroup v2 membership is unavailable")


def verify_system_service_cgroup(expected_unit: str) -> None:
    if "/" in expected_unit or not expected_unit.endswith(".service"):
        raise SandboxError("invalid expected transient service name")
    expected_path = f"/system.slice/{expected_unit}"
    actual_path = read_unified_cgroup()
    if actual_path != expected_path:
        raise SandboxError(
            f"probe is not in the expected system service cgroup "
            f"({actual_path!r}, expected {expected_path!r})"
        )


def _unit_ip_property(expected_unit: str, property_name: str) -> set:
    systemctl = _trusted_command("systemctl")
    try:
        result = subprocess.run(
            [
                systemctl,
                "--system",
                "show",
                f"--property={property_name}",
                "--value",
                "--",
                expected_unit,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SandboxError(f"cannot inspect system service properties: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise SandboxError(f"cannot read {property_name}: {detail}")
    return set(result.stdout.split())


def verify_unit_ip_properties(expected_unit: str) -> None:
    deny = _unit_ip_property(expected_unit, "IPAddressDeny")
    allow = _unit_ip_property(expected_unit, "IPAddressAllow")
    deny_all = "any" in deny or {"0.0.0.0/0", "::/0"}.issubset(deny)
    if not deny_all:
        raise SandboxError(f"system service IPAddressDeny is not 'any': {sorted(deny)}")
    if not allow or not _allowlist_is_loopback_only(allow):
        raise SandboxError(
            "system service IPAddressAllow is not exactly localhost: "
            f"{sorted(allow)}"
        )
    for parent in ("system.slice", "-.slice"):
        inherited_allow = _unit_ip_property(parent, "IPAddressAllow")
        if inherited_allow and not _allowlist_is_loopback_only(inherited_allow):
            raise SandboxError(
                f"inherited {parent} IPAddressAllow permits non-loopback traffic: "
                f"{sorted(inherited_allow)}"
            )


def _allowlist_is_loopback_only(entries: set) -> bool:
    for entry in entries:
        if entry == "localhost":
            continue
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError:
            return False
        loopback = ipaddress.ip_network(
            "127.0.0.0/8" if network.version == 4 else "::1/128"
        )
        if not network.subnet_of(loopback):
            return False
    return True


def verify_network_sandbox(expected_unit: str) -> None:
    verify_system_service_cgroup(expected_unit)
    verify_unit_ip_properties(expected_unit)
    addresses = discover_non_loopback_addresses()
    if not addresses:
        raise SandboxError("no configured non-loopback IPv4 or IPv6 address to test")
    for address in addresses:
        verify_loopback(address.family)
        verify_non_loopback_denied(address, socket.SOCK_DGRAM)
        verify_non_loopback_denied(
            address,
            socket.SOCK_STREAM,
            udp_permission_denial_proven=True,
        )


def _read_proc_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _looks_like_zed_process(process: Path) -> bool:
    comm = _read_proc_text(process / "comm").strip().lower()
    try:
        executable = os.readlink(process / "exe")
    except OSError:
        executable = ""
    cmdline = _read_proc_text(process / "cmdline").replace("\0", " ")

    if comm in ZED_EXECUTABLE_NAMES or comm.startswith("zed-"):
        return True
    normalized_executable = (
        executable[: -len(" (deleted)")]
        if executable.endswith(" (deleted)")
        else executable
    )
    executable_name = os.path.basename(normalized_executable).lower()
    if executable_name in ZED_EXECUTABLE_NAMES:
        return True
    return bool(ZED_APP_EXECUTABLE.search(executable) or ZED_APP_EXECUTABLE.search(cmdline))


def _process_is_in_verified_service(process: Path, uid: int) -> bool:
    cgroup = _read_proc_text(process / "cgroup")
    for row in cgroup.splitlines():
        fields = row.split(":", 2)
        if len(fields) != 3 or fields[0] != "0" or fields[1] != "":
            continue
        path = fields[2]
        prefix = f"/system.slice/zed-secure-{uid}-"
        suffix = path[len(prefix) :] if path.startswith(prefix) else ""
        return bool(suffix and suffix.endswith(".service") and "/" not in suffix)
    return False


def ensure_no_unsandboxed_zed_processes(
    proc_root: Union[Path, str] = "/proc",
    uid: Optional[int] = None,
    current_pid: Optional[int] = None,
) -> None:
    """Reject plausible same-user Zed processes outside a system service."""
    root = Path(proc_root)
    expected_uid = os.getuid() if uid is None else uid
    own_pid = os.getpid() if current_pid is None else current_pid
    unsafe: List[str] = []
    try:
        processes = list(root.iterdir())
    except OSError as exc:
        raise SandboxError(f"cannot inspect running processes: {exc}") from exc

    for process in processes:
        if not process.name.isdigit() or int(process.name) == own_pid:
            continue
        try:
            if process.stat().st_uid != expected_uid:
                continue
        except OSError:
            continue
        if not _looks_like_zed_process(process):
            continue
        if not _process_is_in_verified_service(process, expected_uid):
            unsafe.append(process.name)

    if unsafe:
        raise SandboxError(
            "an unsandboxed Zed process is already running "
            f"(PID {', '.join(sorted(unsafe, key=int))}); close it and retry"
        )


def _trusted_command(name: str) -> str:
    """Resolve an executable whose file and directory chain are root-controlled."""
    candidates = list(TRUSTED_COMMAND_CANDIDATES.get(name, ()))
    path_candidate = shutil.which(name)
    if path_candidate is not None:
        candidates.append(path_candidate)
    for candidate in dict.fromkeys(candidates):
        try:
            command = os.path.realpath(candidate)
            metadata = os.stat(command)
        except OSError:
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0:
            continue
        if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            continue
        if not os.access(command, os.X_OK):
            continue
        trusted_parents = True
        for parent in Path(command).parents:
            try:
                parent_metadata = parent.stat()
            except OSError:
                trusted_parents = False
                break
            if parent_metadata.st_uid != 0 or parent_metadata.st_mode & (
                stat.S_IWGRP | stat.S_IWOTH
            ):
                trusted_parents = False
                break
        if trusted_parents:
            return command
    raise SandboxError(f"trusted root-owned command not found: {name}")


def _validated_askpass(uid: int) -> str:
    configured = os.environ.get("SUDO_ASKPASS", "")
    if not configured or not os.path.isabs(configured):
        raise SandboxError(
            "desktop launch has no terminal; configure an absolute trusted "
            "SUDO_ASKPASS helper or launch zed-secure from a terminal"
        )
    helper = os.path.realpath(configured)
    try:
        metadata = os.stat(helper)
    except OSError as exc:
        raise SandboxError(f"cannot use SUDO_ASKPASS helper: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode) or not os.access(helper, os.X_OK):
        raise SandboxError("SUDO_ASKPASS must name an executable regular file")
    if metadata.st_uid not in (0, uid) or metadata.st_mode & (
        stat.S_IWGRP | stat.S_IWOTH
    ):
        raise SandboxError(
            "SUDO_ASKPASS must be owned by root or the invoking user and not "
            "group/world writable"
        )
    for parent in Path(helper).parents:
        try:
            parent_metadata = parent.stat()
        except OSError as exc:
            raise SandboxError(f"cannot validate SUDO_ASKPASS directory: {exc}") from exc
        if parent_metadata.st_uid not in (0, uid) or parent_metadata.st_mode & (
            stat.S_IWGRP | stat.S_IWOTH
        ):
            raise SandboxError(
                "SUDO_ASKPASS directory chain must be owned by root or the "
                "invoking user and not group/world writable"
            )
    return helper


def _has_controlling_terminal() -> bool:
    try:
        descriptor = os.open("/dev/tty", os.O_RDWR | os.O_CLOEXEC)
    except OSError:
        return False
    os.close(descriptor)
    return True


def _service_environment(uid: int, channel: str) -> Tuple[str, Dict[str, str]]:
    home = os.environ.get("HOME")
    if not home or not os.path.isabs(home):
        raise SandboxError("HOME must be an absolute path")
    secure_data_home = os.path.join(home, ".local", "share", "zed-secure", channel)
    os.makedirs(secure_data_home, mode=0o700, exist_ok=True)
    os.chmod(secure_data_home, 0o700)

    environment = {
        key: os.environ[key]
        for key in PASSTHROUGH_ENVIRONMENT
        if key in os.environ and os.environ[key]
    }
    environment.update(
        {
            "HOME": home,
            "XDG_DATA_HOME": secure_data_home,
            "XDG_RUNTIME_DIR": f"/run/user/{uid}",
            "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{uid}/bus",
        }
    )
    for key, value in os.environ.items():
        if key == "LC_ALL" or key.startswith("LC_"):
            environment[key] = value
    return secure_data_home, environment


def launch_system_service(zed_bin: str, channel: str, zed_args: List[str]) -> None:
    if not os.path.isabs(zed_bin) or not os.access(zed_bin, os.X_OK):
        raise SandboxError(f"Zed binary is not an executable absolute path: {zed_bin}")

    uid = os.getuid()
    if uid == 0:
        raise SandboxError(
            "sandboxed Zed must be launched by the non-root desktop user; "
            "do not run zed-secure with sudo"
        )
    gid = os.getgid()
    unit = f"zed-secure-{uid}-{os.getpid()}"
    systemd_run = _trusted_command("systemd-run")
    python = _trusted_command("python3")
    helper = os.path.abspath(__file__)
    _secure_data_home, environment = _service_environment(uid, channel)

    command = [
        systemd_run,
        "--system",
        "--quiet",
        "--wait",
        "--pipe",
        "--collect",
        "--service-type=exec",
        f"--unit={unit}",
        f"--uid={uid}",
        f"--gid={gid}",
        f"--working-directory={os.getcwd()}",
        "--property=KillMode=control-group",
        "--property=IPAddressDeny=any",
        "--property=IPAddressAllow=localhost",
    ]
    command.extend(f"--setenv={key}={value}" for key, value in sorted(environment.items()))
    command.extend(
        [
            "--",
            python,
            helper,
            "inside",
            f"--expected-unit={unit}.service",
            f"--zed-bin={zed_bin}",
            "--",
            *zed_args,
        ]
    )
    if uid != 0:
        sudo = _trusted_command("sudo")
        if _has_controlling_terminal():
            command = [sudo, "--", *command]
        else:
            os.environ["SUDO_ASKPASS"] = _validated_askpass(uid)
            command = [sudo, "-A", "--", *command]
    os.execv(command[0], command)


def exec_inside_sandbox(expected_unit: str, zed_bin: str, zed_args: List[str]) -> None:
    verify_network_sandbox(expected_unit)
    ensure_no_unsandboxed_zed_processes()
    if not os.path.isabs(zed_bin) or not os.access(zed_bin, os.X_OK):
        raise SandboxError(f"Zed binary is not executable: {zed_bin}")
    os.execve(zed_bin, [zed_bin, "--foreground", *zed_args], os.environ.copy())


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    probe = subparsers.add_parser("probe")
    probe.add_argument("--expected-unit", required=True)
    launch = subparsers.add_parser("launch")
    launch.add_argument("--zed-bin", required=True)
    launch.add_argument("--channel", choices=ALLOWED_CHANNELS, required=True)
    launch.add_argument("zed_args", nargs=argparse.REMAINDER)
    inside = subparsers.add_parser("inside")
    inside.add_argument("--expected-unit", required=True)
    inside.add_argument("--zed-bin", required=True)
    inside.add_argument("zed_args", nargs=argparse.REMAINDER)
    return parser.parse_args(argv)


def _without_separator(arguments: List[str]) -> List[str]:
    return arguments[1:] if arguments and arguments[0] == "--" else arguments


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.command == "probe":
            verify_network_sandbox(args.expected_unit)
        elif args.command == "launch":
            launch_system_service(
                args.zed_bin, args.channel, _without_separator(args.zed_args)
            )
        elif args.command == "inside":
            exec_inside_sandbox(
                args.expected_unit, args.zed_bin, _without_separator(args.zed_args)
            )
    except SandboxError as exc:
        print(f"zed-secure sandbox verification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
