#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ink_test_dir=$(mktemp -d /tmp/pencilcase-ink-tests.XXXXXX)
trap 'rm -rf "$ink_test_dir"' EXIT
xcrun swiftc -O -default-isolation MainActor -module-cache-path "$ink_test_dir/modules" PencilCase/DrawingPreferences.swift PencilCase/MarkerStroke.swift Tests/InkRenderingTests.swift -o "$ink_test_dir/tests"
"$ink_test_dir/tests"
