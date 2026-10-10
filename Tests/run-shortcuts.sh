#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
shortcut_test_dir=$(mktemp -d /tmp/pencilcase-shortcut-tests.XXXXXX)
trap 'rm -rf "$shortcut_test_dir"' EXIT
xcrun swiftc -default-isolation MainActor -module-cache-path "$shortcut_test_dir/modules" PencilCase/ToolShortcuts.swift Tests/ShortcutTests.swift -o "$shortcut_test_dir/tests"
"$shortcut_test_dir/tests"
