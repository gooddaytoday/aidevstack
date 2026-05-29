.PHONY: test lint
test:
	sh tests/run.sh
lint:
	sh -n scripts/install-zed-secure.sh \
		scripts/zed-security-settings.sh \
		scripts/install-zed-no-ai.sh \
		scripts/install-zed-local-llm.sh
