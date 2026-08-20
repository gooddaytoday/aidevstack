# Root-backed systemd network sandbox

## Problem

The Linux installer currently treats this command as proof that its network
sandbox works:

```sh
systemd-run --user --scope \
  -p IPAddressDeny=any -p IPAddressAllow=localhost true
```

The user service manager can accept those properties and return success without
installing the cgroup BPF filters. The generated `zed-secure` wrapper repeats the
same ineffective `--user --scope` launch and can therefore expose proprietary
code to unrestricted network egress while reporting that the sandbox is
enabled.

## Scope and security claim

Replace the user-manager launch with a fail-closed transient service managed by
the system manager (PID 1). The supported claim is deliberately narrow:

> Direct IPv4 and IPv6 traffic from processes in the Zed service cgroup is
> denied except for loopback addresses.

This is not a complete hostile-code boundary. Unix sockets, the session D-Bus,
already-open file descriptors, and a service reachable over loopback can broker
network access. The README and installer summary must use the narrower claim.

Windows behavior and the opt-in UID-wide nft firewall are outside this change.

## Chosen architecture

### Privileged backend

When network sandboxing is enabled, `zed-secure` launches a transient system
service through an authenticated `systemd-run --system` call. Administrative
authentication may be requested on every launch. The service uses:

- a unique `zed-secure-<uid>-<launcher-pid>.service` name;
- `--service-type=exec`, `--wait`, `--pipe`, and `--collect`;
- the invoking numeric UID and GID, so Zed never runs as root and systemd
  initializes the user's supplementary groups;
- `KillMode=control-group`, so children cannot survive the foreground service
  process or escape filtering if it exits;
- `IPAddressDeny=any` and `IPAddressAllow=localhost`;
- the caller's working directory;
- an explicit allowlist of GUI/session environment variables rather than
  wholesale `sudo -E` environment preservation.

The environment allowlist covers `HOME`, `PATH`, the XDG config/cache paths, an
`XDG_RUNTIME_DIR` derived from the numeric UID, the corresponding local user
D-Bus address, Wayland/X11 display variables, desktop/session variables,
locale variables, `SHELL`, and `SSH_AUTH_SOCK`. Provider API keys remain
cleared before launch. Commands executed with privilege use canonical
executables whose files and entire directory chains are root-owned and not
group/world writable; caller `PATH` entries cannot select the privileged
backend. All user-controlled arguments reach only a process that has already
dropped to the invoking user.

The protected instance gets a dedicated, mode-0700 `XDG_DATA_HOME` below
`~/.local/share/zed-secure/<channel>`. Zed places its Linux IPC socket below its
data directory, so this prevents the protected CLI from forwarding a request to
the ordinary unsandboxed instance even when both start concurrently. The
secure instance consequently has separate extensions, databases, logs, and
other data-directory state; its configuration directory remains the user's
selected `XDG_CONFIG_HOME`. The implementation does not rely on Zed's
`--user-data-dir` option because released Linux CLI versions have not applied
it reliably when another instance exists.

Without a controlling terminal, the launcher requires an absolute
`SUDO_ASKPASS` executable with a root/user-owned, non-writable file and parent
chain, canonicalizes the path, and invokes `sudo -A`. Otherwise it fails with
instructions to use a terminal or configure that trusted helper. It must never
fall back to a direct Zed execution. No broad `NOPASSWD` rule for `systemd-run`
is installed or recommended.

### Sandbox probe and exec helper

Add a dependency-free Python helper shipped beside the installer and copied to
the user's `~/.local/share/zed-secure` directory. The helper always runs as the
unprivileged target user inside the transient service for enforcement. It has
three narrow commands:

1. `probe`, used inside the installation-time service;
2. `launch`, which constructs the privileged transient-service request;
3. `inside`, which probes and then `execve()`s the configured Zed binary with
   `--foreground` and the original arguments.

The probe verifies the system manager's normalized `IPAddressDeny` and
`IPAddressAllow` values and then performs observable enforcement checks; unit
properties alone are not accepted as proof:

1. discover active non-loopback local interface addresses using Linux standard
   interfaces (`socket.if_nameindex`, `SIOCGIFADDR`, and `/proc/net/if_inet6`);
2. for every configured address family, exchange a UDP datagram over that
   family's loopback address (`127.0.0.1` or `::1`);
3. attempt both a UDP send and a TCP connection to listeners bound to a
   discovered non-loopback address for that family, with short timeouts;
4. require `EPERM` or `EACCES` from UDP as positive proof that the cgroup filter
   is attached; then require the TCP connection not to succeed. systemd's
   cgroup-skb program may silently drop the TCP SYN, so a TCP timeout is accepted
   only after the same-family UDP permission denial has already been observed.

IPv4 and IPv6 are evaluated independently. A family is configured only when an
UP, non-loopback interface has a local address in that family. Every configured
family must pass both its loopback exchange and its permission-denied
non-loopback send. IPv6 with only `::1` is therefore skipped, not treated as a
partially verified family. At least one family must be configured and
positively denied; otherwise the result is inconclusive and fails closed. A UDP
timeout, route failure, or refusal is not positive evidence; a TCP timeout is
only a secondary non-escape check after positive same-family UDP evidence. No
TEST-NET or route-error fallback is accepted because `ENETUNREACH`, UDP timeout,
and similar errors do not prove that cgroup filtering is active.

The launcher passes the unique expected unit name to the helper. The helper
requires its own unified cgroup path to be exactly
`/system.slice/<expected-unit>.service`; a matching basename below
`/user.slice` or any other hierarchy is rejected. Likewise, an existing Zed
process is considered protected only when its cgroup path matches
`/system.slice/zed-secure-<uid>-*.service`. This provenance check prevents a
user-manager unit with a convincing name from satisfying the assertion.

Before starting Zed the helper conservatively scans all same-UID processes,
using `/proc/<pid>/exe`, `/proc/<pid>/cmdline`, and `/proc/<pid>/comm`. It
recognizes the supported channel names, alternate installation paths, CLI
children, and deleted/replaced Zed executables rather than comparing only one
resolved inode. Any plausible Zed process outside a verified system-service
cgroup stops the launch and asks the user to close it. A false positive is
safer than forwarding into an unsandboxed GUI.

The dedicated data directory gives protected and ordinary launches distinct
IPC sockets, which closes the concurrent-start and already-running forwarding
race for normal invocations. The process scan is a second, conservative guard.
`--foreground` keeps the new application process in the service cgroup. A new
window flag alone is insufficient because Zed uses a single process and local
socket forwarding. A user who deliberately starts an unsandboxed Zed with the
secure data directory can still bypass this wrapper; preventing actions by the
invoking account is outside the threat model.

## Installer behavior

`check_sandbox_available` is replaced with a privileged `--probe-only`
transient service using the same properties and helper as the runtime wrapper.
It checks for `systemd-run`, Python 3, the helper, and an authentication backend.

- Successful probe: record and report `verified system-service sandbox`.
- Failed probe without `--allow-no-sandbox`: abort before installing or
  modifying Zed.
- Failed probe with `--allow-no-sandbox`: emit a prominent warning, disable the
  sandbox in the generated wrapper, and report it as disabled.
- Dry-run: report `requested (not verified in dry-run)`, never `enabled`.
- Explicit `--no-network-sandbox`: retain the direct wrapper path and report the
  opt-out.

An installed sandbox-enabled wrapper has no environment-variable escape hatch.
Changing to unsandboxed mode requires rerunning the installer with the explicit
CLI opt-out. When sandboxing is enabled, missing `sudo`, `systemd-run`, Python,
the helper, or authorization at launch always produces a nonzero exit without
starting Zed.

## Tests

Add focused tests for the following public behaviors:

- the old `systemd-run --user` backend is never generated;
- dry-run says requested/unverified rather than enabled;
- an ignored-property/fake backend is rejected and never starts fake Zed;
- missing helper, missing privileged backend, cancelled authorization, and
  failed runtime probe are all fail-closed;
- `--allow-no-sandbox` is the only automatic degradation path;
- the generated command targets the system manager, includes the fixed IP
  properties and original UID/GID, and preserves arguments without shell
  interpolation;
- the helper accepts loopback, rejects an unsandboxed non-loopback send,
  requires a UDP permission denial as positive sandbox evidence, and accepts a
  TCP timeout only after that same-family proof;
- IPv4 and IPv6 are checked independently, loopback-only IPv6 is skipped, and
  a machine with no configured non-loopback family is rejected;
- a user-manager cgroup with the expected unit basename is rejected;
- alternate-path and deleted/replaced unsandboxed Zed processes are rejected;
- the dedicated data directory separates the protected IPC socket, including
  during concurrent protected and ordinary startup;
- a successful fake backend preserves working directory and launches fake Zed
  with `--foreground` and the original arguments.

The regular CI suite uses fake `sudo`/`systemd-run` binaries and Python unit
tests, so it needs no privilege. Add a separately gated privileged integration
test that runs the real probe under PID 1 when explicitly enabled; absence of
that environment is reported as skipped, never as proof that the sandbox works.

Run the focused tests, the complete Linux suite, shell/Python syntax checks,
lint, and `git diff --check`.

## Documentation

Update the threat model, CLI table, preset description, summary, and Windows
parity notes to state:

- Linux isolation uses an authenticated transient system service, not a user
  scope;
- Python 3 and a functioning systemd cgroup-BPF firewall are required when the
  sandbox is enabled;
- an administrator prompt can occur on every protected launch;
- desktop launch without a usable authentication agent fails closed;
- the protected instance uses a separate data directory (extensions,
  databases, logs, and IPC state) while sharing the configured settings path;
- the boundary blocks direct non-loopback IP egress but not every possible
  broker through Unix sockets, D-Bus, inherited descriptors, or localhost.

## Non-goals

- installing sudoers or Polkit policy;
- eliminating the per-launch authentication prompt;
- replacing systemd BPF with a new nftables lifecycle;
- isolating filesystem, IPC, devices, or the display server;
- preventing the invoking user from deliberately bypassing the wrapper or
  reusing its dedicated data directory in an unsandboxed process;
- changing the Windows firewall implementation;
- fixing unrelated UID-wide nft uninstall behavior.
