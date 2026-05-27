.PHONY: test lint
test:
	sh tests/run.sh
lint:
	sh -n scripts/install-zed-secure.sh
