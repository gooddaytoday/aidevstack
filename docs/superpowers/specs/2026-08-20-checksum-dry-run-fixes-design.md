# Checksum dry-run follow-up fixes

## Scope

Fix the two confirmed defects found while reviewing the PR #1 remediation:

- make the documented `ZED_INSTALLER_SHA256` placeholder valid shell syntax;
- reject malformed `ZED_INSTALLER_SHA256` values before a network-install
  dry-run reports success.

No other installer behavior or documentation is in scope.

## Design

### Documentation

Replace the angle-bracket placeholder in the README export example with the
shell-safe token `YOUR_TRUSTED_64_CHARACTER_SHA256`. The token remains visibly
replaceable, while copying the environment block no longer causes a shell parse
error.

### Installer validation

Keep validation local to `install_zed_from_network`. When
`ZED_INSTALLER_SHA256` is non-empty, require exactly 64 hexadecimal characters
before the function's dry-run branch and before creating or downloading a
temporary installer file. The existing digest calculation and comparison remain
after the complete download.

This preserves the current behavior for an unset checksum and for offline
installs, where the upstream network-installer checksum is irrelevant.

### Error handling

A malformed checksum must terminate both dry-run and real network installs with
a nonzero exit code and the existing clear validation message. No temporary file
or network request should be needed to detect this input error.

## Verification

Extend `tests/test_network_install_hardening.sh` with table-driven malformed
checksum cases that independently cover:

- a hexadecimal value shorter than 64 characters;
- a hexadecimal value longer than 64 characters;
- a 64-character value containing a non-hexadecimal character.

For each case, run with `--dry-run` and assert a nonzero exit plus the existing
validation message. Also run one malformed case in real mode with instrumented
`mktemp` and fake `curl` commands; assert that neither command is called, proving
validation happens before temporary-file creation and network access.

Verify the replacement README export with `sh -n -c`, then run the focused
test, the complete test suite, lint, and `git diff --check`.
