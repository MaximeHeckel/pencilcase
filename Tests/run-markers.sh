#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
marker_test_dir=$(mktemp -d /tmp/pencilcase-marker-tests.XXXXXX)
trap 'rm -rf "$marker_test_dir"' EXIT
sources=()
for source in PencilCase/*.swift; do
    case "$source" in */MyApp.swift|*/ContentView.swift) continue ;; esac
    sources+=("$source")
done
xcrun swiftc -default-isolation MainActor -module-cache-path "$marker_test_dir/modules" "${sources[@]}" Tests/MarkerTests.swift -o "$marker_test_dir/tests"
"$marker_test_dir/tests" "${1:-$marker_test_dir/preview.png}"
