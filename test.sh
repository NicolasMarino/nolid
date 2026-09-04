#!/usr/bin/env bash
#
# Runs the NoLid test suite. No XCTest, no Package.swift, no dependencies —
# just a binary that exits non-zero when an expectation fails.
#
set -euo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"
BINARY="build/nolid-tests"

mkdir -p build

# Before the glob below, not after: the generated file has to exist for the
# glob to see it. On a machine that has built before it exists either way,
# which is exactly why the wrong order passed locally and failed on a clean
# checkout.
Tools/generate-version.sh > /dev/null

# Sources/main.swift is excluded: it holds the app's top-level code, and only
# one file per module may have any. Tests/main.swift is the entry point here.
SOURCES=()
for file in Sources/*.swift; do
    [ "$file" = "Sources/main.swift" ] || SOURCES+=("$file")
done

echo "==> Building tests (${TARGET})"
swiftc -wmo \
    -target "$TARGET" \
    -module-name NoLidTests \
    -framework Carbon \
    "${SOURCES[@]}" Tests/*.swift \
    -o "$BINARY"

echo "==> Running"
"$BINARY"
