#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
momentum_test_dir=$(mktemp -d /tmp/pencilcase-momentum-tests.XXXXXX)
trap 'rm -rf "$momentum_test_dir"' EXIT
xcrun swiftc -module-cache-path "$momentum_test_dir/modules" PencilCase/RulerMomentum.swift PencilCase/InstrumentMomentum.swift Tests/MomentumTests.swift -o "$momentum_test_dir/tests"
"$momentum_test_dir/tests"
