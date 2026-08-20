# PR #1 review fixes design

## Scope

Verify every CodeRabbit finding on `gooddaytoday/aidevstack#1` against
`fe9f39a97b49bc8cb786c2c893308a8b982bce8d`. Fix confirmed inline defects and
nitpicks that provide concrete security or reliability hardening. Do not change
valid behavior merely to follow a suggestion.

The audit confirmed 18 inline findings and 5 useful hardening nitpicks. It
rejected seven findings as already covered, valid conservative behavior, or
cosmetic-only advice.

## Changes

### CI

- Pin both `actions/checkout` steps to the verified `v4.4.0` commit and disable
  persisted credentials.
- Remove `-SkipPublisherCheck` from PowerShell module installation.
- Keep `PSGallery` trusted: that setting controls the noninteractive repository
  prompt and does not bypass publisher validation.

### Linux installer

- Make the local-LLM preset default to the standard `/v1` base URL and honor
  `ZED_LLM_API_URL`; users can still include a vendor-specific query explicitly.
- Add an IPv6 loopback exception/drop rule alongside the existing IPv4 UID-wide
  firewall rule and update user-facing documentation.
- Clear every currently documented Zed provider API-key environment variable.
- Download the upstream installer completely before execution, never stream it
  into `sh`; support optional SHA-256 verification and clearly warn when it is
  absent.
- Extract offline bundles into a same-filesystem staging directory, validate the
  expected app executable, and swap the staged app into place only after success.
- Make the running-Zed warning explicitly say not to restart Zed until the
  installer finishes.

### Linux tests

- Fail the test runner when it discovers zero tests.
- Fix literal-path and key-existence assertions, the blocklist wrapper oracle,
  the missing merged `search_web` assertion, and wrapper exit handling.
- Isolate `HOME`, `XDG_CONFIG_HOME`, and `XDG_DATA_HOME` for affected real-mode
  tests and provision a fake installed Zed so tests cannot write to the caller's
  profile or fetch from the network.
- Add focused regression coverage for network-download staging, checksum
  mismatch, atomic offline extraction, provider-key clearing, and IPv6 rules.

### Windows installer

- Make the local-LLM preset default to the standard `/v1` base URL and honor
  `ZED_LLM_API_URL`, matching the Linux preset.
- Clear the same documented built-in provider API-key variables as the Linux
  launcher.
- Normalize a trailing slash before deriving `/completions`.
- Prefer and validate channel-specific install paths; a stable executable from
  `PATH` or the registry must not satisfy preview/nightly/dev resolution.
- Share one four-scope shortcut candidate list between repair and restore so
  uninstall restores ProgramData and Public shortcuts too.
- Require `auto_update: false` in the raw-text JSONC verification fallback.

### Windows tests

- Add missing exit-code assertions.
- Cover trailing-slash URLs, channel resolution, all shortcut scopes, and the
  malformed-JSONC fallback.

## Explicit non-changes

- Do not add a Markdown fence language when no MD040 policy exists.
- Do not add a redundant pre-check before a fail-closed dot-source.
- Do not broaden the canonical loopback allowlist with unsafe `127.*` matching.
- Do not remove `PSGallery` trust under the false claim that it disables signing.
- Do not duplicate already existing Windows CLI assertions.
- Do not combine correct `sed` calls or add Makefile-only ergonomics.

## Verification

- Run all focused Linux tests and the complete Linux suite under an isolated
  profile, plus `sh -n` and shell lint when available.
- Run Pester and PSScriptAnalyzer when PowerShell is available; otherwise retain
  explicit unexecuted-platform evidence and rely on narrow, reviewable Pester
  regressions rather than claiming local Windows execution.
- Re-read every PR thread against the final diff and ensure each confirmed item
  has code and test evidence while each rejected item remains intentionally
  unchanged.

No commit, push, review reply, or thread resolution is part of this design.
