.PHONY: test lint test-windows lint-windows
test:
	sh tests/run.sh
lint:
	sh -n scripts/install-zed-secure.sh \
		scripts/zed-security-settings.sh \
		scripts/install-zed-no-ai.sh \
		scripts/install-zed-local-llm.sh

# Windows targets (run on Windows, or anywhere PowerShell 7 'pwsh' is installed).
test-windows:
	pwsh -NoProfile -File tests/windows/Invoke-Tests.ps1
lint-windows:
	pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/windows -Recurse -Severity Error,Warning"
