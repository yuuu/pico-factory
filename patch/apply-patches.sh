#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "Applying picoruby-esp32_xtensa-esp.patch..."
git -C "$REPO_ROOT/components/picoruby-esp32" apply "$REPO_ROOT/picoruby-esp32_xtensa-esp.patch"

echo "Applying picoruby_nested.patch..."
git -C "$REPO_ROOT/components/picoruby-esp32/picoruby" apply "$REPO_ROOT/picoruby_nested.patch"

echo "Done."
