#!/bin/bash
# Build the agent's AgentCore Runtime code bundle: agent/main.py plus its
# dependencies, installed for the runtime's platform (Linux arm64, CPython
# 3.13), zipped to build/agent.zip. No container build is involved; AgentCore
# Runtime runs the bundle directly (direct code deployment).
#
#   scripts/build.sh
#
# Prerequisites: python3 with pip, and zip. Only binary wheels are used, so the
# bundle builds the same way on any host OS.
set -euo pipefail

EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="${EXAMPLE_DIR}/agent"
BUILD_DIR="${EXAMPLE_DIR}/build"
PKG_DIR="${BUILD_DIR}/package"

for tool in python3 zip; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done

rm -rf "$PKG_DIR" "${BUILD_DIR}/agent.zip"
mkdir -p "$PKG_DIR"

python3 -m pip install --quiet --disable-pip-version-check \
  --target "$PKG_DIR" \
  --platform manylinux2014_aarch64 --implementation cp --python-version 3.13 \
  --only-binary=:all: \
  --requirement "${AGENT_DIR}/requirements.txt"

cp "${AGENT_DIR}/main.py" "$PKG_DIR/"

# Byte-code caches are host-specific; a fixed timestamp keeps the archive's
# content hash (and so the S3 key Terraform derives from it) stable across
# rebuilds of the same sources.
find "$PKG_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$PKG_DIR" -exec touch -h -t 202001010000 {} +
(cd "$PKG_DIR" && find . -type f -o -type l | LC_ALL=C sort | zip -q -X -y "${BUILD_DIR}/agent.zip" -@)

echo "Built ${BUILD_DIR}/agent.zip ($(du -h "${BUILD_DIR}/agent.zip" | cut -f1))"
