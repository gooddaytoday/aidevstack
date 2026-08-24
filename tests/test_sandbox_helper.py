#!/usr/bin/env python3
"""Behavior tests for the fail-closed sandbox helper."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "zed-sandbox-launcher.py"
SPEC = importlib.util.spec_from_file_location("zed_sandbox_launcher", HELPER)
assert SPEC is not None and SPEC.loader is not None
SANDBOX = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SANDBOX
SPEC.loader.exec_module(SANDBOX)


class ExistingProcessTests(unittest.TestCase):
    def test_user_manager_unit_with_secure_name_is_rejected(self) -> None:
        uid = os.getuid()
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            process = proc / "4242"
            process.mkdir()
            (process / "comm").write_text("zed\n", encoding="utf-8")
            (process / "cmdline").write_bytes(b"/opt/zed.app/bin/zed\0")
            (process / "cgroup").write_text(
                f"0::/user.slice/user-{uid}.slice/zed-secure-{uid}-7.service\n",
                encoding="ascii",
            )
            (process / "exe").symlink_to("/opt/zed.app/bin/zed (deleted)")

            with self.assertRaises(SANDBOX.SandboxError):
                SANDBOX.ensure_no_unsandboxed_zed_processes(
                    proc_root=proc, uid=uid, current_pid=-1
                )


class NetworkProbeTests(unittest.TestCase):
    @staticmethod
    def _socket_pair(sender_error):
        receiver = mock.MagicMock()
        receiver.__enter__.return_value = receiver
        receiver.getsockname.return_value = ("192.0.2.10", 4242)
        sender = mock.MagicMock()
        sender.__enter__.return_value = sender
        sender.connect.side_effect = sender_error
        sender.sendto.side_effect = sender_error
        return receiver, sender

    def test_tcp_timeout_is_accepted_after_udp_permission_denial(self) -> None:
        address = SANDBOX.InterfaceAddress(SANDBOX.socket.AF_INET, "192.0.2.10")
        receiver, sender = self._socket_pair(SANDBOX.socket.timeout("timed out"))
        with mock.patch.object(
            SANDBOX.socket, "socket", side_effect=[receiver, sender]
        ):
            SANDBOX.verify_non_loopback_denied(
                address,
                SANDBOX.socket.SOCK_STREAM,
                udp_permission_denial_proven=True,
            )

    def test_tcp_timeout_without_udp_proof_is_inconclusive(self) -> None:
        address = SANDBOX.InterfaceAddress(SANDBOX.socket.AF_INET, "192.0.2.10")
        receiver, sender = self._socket_pair(SANDBOX.socket.timeout("timed out"))
        with mock.patch.object(
            SANDBOX.socket, "socket", side_effect=[receiver, sender]
        ):
            with self.assertRaisesRegex(SANDBOX.SandboxError, "inconclusively"):
                SANDBOX.verify_non_loopback_denied(
                    address,
                    SANDBOX.socket.SOCK_STREAM,
                )

    def test_tcp_etimedout_is_accepted_after_udp_permission_denial(self) -> None:
        class LegacySocketTimeout(OSError):
            pass

        address = SANDBOX.InterfaceAddress(SANDBOX.socket.AF_INET, "192.0.2.10")
        receiver, sender = self._socket_pair(OSError(SANDBOX.errno.ETIMEDOUT, "timed out"))
        with mock.patch.object(
            SANDBOX.socket, "timeout", LegacySocketTimeout
        ), mock.patch.object(
            SANDBOX.socket, "socket", side_effect=[receiver, sender]
        ):
            SANDBOX.verify_non_loopback_denied(
                address,
                SANDBOX.socket.SOCK_STREAM,
                udp_permission_denial_proven=True,
            )

    def test_udp_timeout_is_never_positive_sandbox_evidence(self) -> None:
        address = SANDBOX.InterfaceAddress(SANDBOX.socket.AF_INET, "192.0.2.10")
        receiver, sender = self._socket_pair(SANDBOX.socket.timeout("timed out"))
        with mock.patch.object(
            SANDBOX.socket, "socket", side_effect=[receiver, sender]
        ):
            with self.assertRaisesRegex(SANDBOX.SandboxError, "inconclusively"):
                SANDBOX.verify_non_loopback_denied(address, SANDBOX.socket.SOCK_DGRAM)

    def test_non_loopback_allow_from_parent_slice_is_rejected(self) -> None:
        properties = {
            ("zed-secure-1000-1.service", "IPAddressDeny"): {
                "0.0.0.0/0",
                "::/0",
            },
            ("zed-secure-1000-1.service", "IPAddressAllow"): {
                "127.0.0.0/8",
                "::1/128",
            },
            ("system.slice", "IPAddressAllow"): {"198.51.100.0/24"},
            ("-.slice", "IPAddressAllow"): set(),
        }
        with mock.patch.object(
            SANDBOX,
            "_unit_ip_property",
            side_effect=lambda unit, name: properties[(unit, name)],
        ):
            with self.assertRaisesRegex(SANDBOX.SandboxError, "inherited"):
                SANDBOX.verify_unit_ip_properties("zed-secure-1000-1.service")

    def test_unit_with_deny_all_and_loopback_allow_is_accepted(self) -> None:
        values = {
            "IPAddressDeny": "0.0.0.0/0 ::/0\n",
            "IPAddressAllow": "127.0.0.0/8 ::1/128\n",
        }

        def property_result(command, **_kwargs):
            property_name = command[command.index("--value") - 1].split("=", 1)[1]
            return mock.Mock(returncode=0, stdout=values[property_name], stderr="")

        with mock.patch.object(
            SANDBOX, "_trusted_command", return_value="/usr/bin/systemctl"
        ), mock.patch.object(SANDBOX.subprocess, "run", side_effect=property_result):
            SANDBOX.verify_unit_ip_properties("zed-secure-1000-1.service")

    def test_unit_with_broad_allow_policy_is_rejected(self) -> None:
        def property_result(_command, **_kwargs):
            return mock.Mock(returncode=0, stdout="0.0.0.0/0 ::/0\n", stderr="")

        with mock.patch.object(
            SANDBOX, "_trusted_command", return_value="/usr/bin/systemctl"
        ), mock.patch.object(SANDBOX.subprocess, "run", side_effect=property_result):
            with self.assertRaisesRegex(SANDBOX.SandboxError, "IPAddressAllow"):
                SANDBOX.verify_unit_ip_properties("zed-secure-1000-1.service")

    def test_probe_rejects_same_named_user_manager_cgroup(self) -> None:
        unit = "zed-secure-1000-9.service"
        with mock.patch.object(
            SANDBOX,
            "read_unified_cgroup",
            return_value=f"/user.slice/user-1000.slice/{unit}",
        ):
            with self.assertRaisesRegex(SANDBOX.SandboxError, "system service cgroup"):
                SANDBOX.verify_system_service_cgroup(unit)

    def test_no_non_loopback_family_is_inconclusive(self) -> None:
        with mock.patch.object(SANDBOX, "verify_system_service_cgroup"), mock.patch.object(
            SANDBOX, "verify_unit_ip_properties"
        ), mock.patch.object(
            SANDBOX, "discover_non_loopback_addresses", return_value=[]
        ):
            with self.assertRaisesRegex(SANDBOX.SandboxError, "no configured"):
                SANDBOX.verify_network_sandbox("zed-secure-1000-1.service")

    def test_every_configured_address_family_must_be_denied(self) -> None:
        addresses = [
            SANDBOX.InterfaceAddress(SANDBOX.socket.AF_INET, "192.0.2.10"),
            SANDBOX.InterfaceAddress(SANDBOX.socket.AF_INET6, "2001:db8::10", 2),
        ]
        with mock.patch.object(SANDBOX, "verify_system_service_cgroup"), mock.patch.object(
            SANDBOX, "verify_unit_ip_properties"
        ), mock.patch.object(
            SANDBOX, "discover_non_loopback_addresses", return_value=addresses
        ), mock.patch.object(SANDBOX, "verify_loopback") as loopback, mock.patch.object(
            SANDBOX,
            "verify_non_loopback_denied",
            side_effect=[None, None, None, SANDBOX.SandboxError("IPv6 escaped")],
        ) as denied:
            with self.assertRaisesRegex(SANDBOX.SandboxError, "IPv6 escaped"):
                SANDBOX.verify_network_sandbox("zed-secure-1000-1.service")

        self.assertEqual(loopback.call_count, 2)
        self.assertEqual(denied.call_count, 4)
        self.assertEqual(
            denied.call_args_list[1].kwargs,
            {"udp_permission_denial_proven": True},
        )
        self.assertEqual(
            denied.call_args_list[3].kwargs,
            {"udp_permission_denial_proven": True},
        )


class ExecTests(unittest.TestCase):
    def test_desktop_launch_uses_canonical_askpass_with_sudo_a(self) -> None:
        real_stat = os.stat
        namespace_root_uid = real_stat("/").st_uid

        def host_root_stat(path, *args, **kwargs):
            metadata = real_stat(path, *args, **kwargs)
            if metadata.st_uid != namespace_root_uid:
                return metadata
            fields = list(metadata)
            fields[4] = 0
            return os.stat_result(fields)

        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            zed = home / "zed"
            zed.write_text("#!/bin/sh\n", encoding="utf-8")
            zed.chmod(0o700)
            commands = {
                "python3": "/usr/bin/python3",
                "systemd-run": "/usr/bin/systemd-run",
                "sudo": "/usr/bin/sudo",
            }
            with mock.patch.dict(
                SANDBOX.os.environ,
                {"HOME": str(home), "PATH": "/usr/bin", "SUDO_ASKPASS": "/bin/true"},
                clear=True,
            ), mock.patch.object(SANDBOX.os, "getuid", return_value=1234), mock.patch.object(
                SANDBOX.os, "getgid", return_value=4321
            ), mock.patch.object(
                SANDBOX.os, "stat", side_effect=host_root_stat
            ), mock.patch.object(
                SANDBOX.Path, "stat", host_root_stat
            ), mock.patch.object(
                SANDBOX, "_trusted_command", side_effect=lambda name: commands[name]
            ), mock.patch.object(
                SANDBOX, "_has_controlling_terminal", return_value=False
            ), mock.patch.object(SANDBOX.os, "execv") as execute:
                SANDBOX.launch_system_service(str(zed), "stable", [])
                canonical_askpass = SANDBOX.os.environ["SUDO_ASKPASS"]

            self.assertEqual(execute.call_args.args[1][:3], ["/usr/bin/sudo", "-A", "--"])
            self.assertEqual(canonical_askpass, os.path.realpath("/bin/true"))

    def test_desktop_launch_without_trusted_askpass_fails_before_sudo(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            zed = home / "zed"
            zed.write_text("#!/bin/sh\n", encoding="utf-8")
            zed.chmod(0o700)
            commands = {
                "python3": "/usr/bin/python3",
                "systemd-run": "/usr/bin/systemd-run",
                "sudo": "/usr/bin/sudo",
            }
            with mock.patch.dict(
                SANDBOX.os.environ, {"HOME": str(home), "PATH": "/usr/bin"}, clear=True
            ), mock.patch.object(SANDBOX.os, "getuid", return_value=1234), mock.patch.object(
                SANDBOX.os, "getgid", return_value=4321
            ), mock.patch.object(
                SANDBOX, "_trusted_command", side_effect=lambda name: commands[name]
            ), mock.patch.object(
                SANDBOX, "_has_controlling_terminal", return_value=False
            ), mock.patch.object(
                SANDBOX.os, "execv"
            ):
                with self.assertRaisesRegex(SANDBOX.SandboxError, "SUDO_ASKPASS"):
                    SANDBOX.launch_system_service(str(zed), "stable", [])

    def test_user_writable_systemd_run_from_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "systemd-run"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake.chmod(0o700)
            with mock.patch.object(
                SANDBOX, "TRUSTED_COMMAND_CANDIDATES", {"systemd-run": ()}
            ), mock.patch.dict(SANDBOX.os.environ, {"PATH": directory}):
                with self.assertRaisesRegex(SANDBOX.SandboxError, "trusted"):
                    SANDBOX._trusted_command("systemd-run")

    def test_launcher_rejects_running_zed_as_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            zed = Path(directory) / "zed"
            zed.write_text("#!/bin/sh\n", encoding="utf-8")
            zed.chmod(0o700)
            with mock.patch.object(SANDBOX.os, "getuid", return_value=0), mock.patch.object(
                SANDBOX.os, "execv"
            ):
                with self.assertRaisesRegex(SANDBOX.SandboxError, "non-root"):
                    SANDBOX.launch_system_service(str(zed), "stable", [])

    def test_launcher_uses_system_manager_and_dedicated_data_home(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            zed = home / "zed"
            zed.write_text("#!/bin/sh\n", encoding="utf-8")
            zed.chmod(0o700)
            commands = {
                "python3": "/usr/bin/python3",
                "systemd-run": "/usr/bin/systemd-run",
                "sudo": "/usr/bin/sudo",
            }
            with mock.patch.dict(
                SANDBOX.os.environ,
                {"HOME": str(home), "PATH": "/usr/bin", "XDG_CONFIG_HOME": "/cfg"},
                clear=True,
            ), mock.patch.object(SANDBOX.os, "getuid", return_value=1234), mock.patch.object(
                SANDBOX.os, "getgid", return_value=4321
            ), mock.patch.object(
                SANDBOX, "_trusted_command", side_effect=lambda name: commands[name]
            ), mock.patch.object(
                SANDBOX, "_has_controlling_terminal", return_value=True
            ), mock.patch.object(
                SANDBOX.os, "execv"
            ) as execute:
                SANDBOX.launch_system_service(
                    str(zed), "preview", ["--version", "path with spaces"]
                )

            command = execute.call_args.args[1]
            secure_data = home / ".local" / "share" / "zed-secure" / "preview"
            self.assertEqual(command[:3], ["/usr/bin/sudo", "--", "/usr/bin/systemd-run"])
            self.assertIn("--system", command)
            self.assertNotIn("--user", command)
            self.assertNotIn("--scope", command)
            self.assertIn("--uid=1234", command)
            self.assertIn("--gid=4321", command)
            self.assertIn("--property=IPAddressDeny=any", command)
            self.assertIn("--property=IPAddressAllow=localhost", command)
            self.assertIn(f"--setenv=XDG_DATA_HOME={secure_data}", command)
            self.assertEqual(command[-3:], ["--", "--version", "path with spaces"])
            self.assertEqual(secure_data.stat().st_mode & 0o777, 0o700)

    def test_verified_launch_forces_foreground_and_preserves_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            zed = Path(directory) / "zed"
            zed.write_text("#!/bin/sh\n", encoding="utf-8")
            zed.chmod(0o700)
            with mock.patch.object(SANDBOX, "verify_network_sandbox"), mock.patch.object(
                SANDBOX, "ensure_no_unsandboxed_zed_processes"
            ), mock.patch.object(SANDBOX.os, "execve") as execute:
                SANDBOX.exec_inside_sandbox(
                    "zed-secure-1000-1.service",
                    str(zed),
                    ["--version", "path with spaces"],
                )

        self.assertEqual(
            execute.call_args.args[1],
            [str(zed), "--foreground", "--version", "path with spaces"],
        )


if __name__ == "__main__":
    unittest.main()
