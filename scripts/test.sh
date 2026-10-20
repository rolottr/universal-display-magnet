#!/usr/bin/env bash
# Run the core test suite. With only the Command Line Tools installed, SwiftPM
# intermittently fails to load the swift-testing macro plugin ("plugin for
# module 'TestingMacros' not found"); that's a toolchain hiccup, so retry.
set -uo pipefail
cd "$(dirname "$0")/.."
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    out=$(swift test 2>&1)
    status=$?
    if ! grep -q "plugin for module 'TestingMacros' not found" <<<"$out"; then
        grep -E "✘|error:|Test run with" <<<"$out" | grep -v "^/Library"
        exit $status
    fi
    echo "(swift-testing macro plugin glitch, retrying $attempt/10)" >&2
done
echo "$out" | tail -20
exit 1
