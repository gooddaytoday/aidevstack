#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test_sandbox_helper.py"
