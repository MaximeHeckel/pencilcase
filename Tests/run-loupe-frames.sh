#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
loupe_test_dir=$(mktemp -d /tmp/pencilcase-loupe-tests.XXXXXX)
trap 'rm -rf "$loupe_test_dir"' EXIT
xcrun swiftc -default-isolation MainActor -module-cache-path "$loupe_test_dir/modules" PencilCase/LoupeRenderer.swift Tests/LoupeFreshFrameTests.swift -o "$loupe_test_dir/tests"
"$loupe_test_dir/tests"
