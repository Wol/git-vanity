#!/usr/bin/env bash
set -euo pipefail

BINARY="$(dirname "$0")/cmake-build-release/git_vanity"

cat test-input.json | "$BINARY"
