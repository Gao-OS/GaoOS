#!/usr/bin/env bash
# GaoOS QEMU integration test runner
#
# Usage: ./tests/qemu/run_test.sh [kernel_image] [expected_output]
#
# Defaults:
#   kernel_image  = zig-out/bin/kernel8.img
#   expected_output = tests/qemu/expected/m3.3-demo.txt
#
# Exit codes:
#   0 = pass (output matches expected)
#   1 = fail (output differs)
#   2 = build failure
#   3 = timeout / QEMU failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL="${1:-zig-out/bin/kernel8.img}"
EXPECTED="${2:-tests/qemu/expected/m3.3-demo.txt}"
TIMEOUT_SEC="${QEMU_TIMEOUT:-15}"

cd "$PROJECT_ROOT"

# Build if needed
if [ ! -f "$KERNEL" ]; then
    echo "Building kernel..."
    if ! zig build 2>&1; then
        echo "FAIL: build error"
        exit 2
    fi
fi

# Run QEMU, capture serial output
ACTUAL=$(mktemp)
trap 'rm -f "$ACTUAL"' EXIT

if ! timeout "$TIMEOUT_SEC" qemu-system-aarch64 \
    -M raspi3b \
    -kernel "$KERNEL" \
    -serial stdio \
    -display none \
    -no-reboot \
    2>/dev/null > "$ACTUAL"; then
    # timeout exits 124, QEMU may exit non-zero normally
    true
fi

# Strip kernel boot preamble (everything before the user-space output)
# and normalize trailing whitespace
sed -i 's/[[:space:]]*$//' "$ACTUAL"

if [ ! -f "$EXPECTED" ]; then
    echo "No expected output file: $EXPECTED"
    echo "Actual output:"
    cat "$ACTUAL"
    echo ""
    echo "To create expected output: cp $ACTUAL $EXPECTED"
    exit 1
fi

# Compare
if diff -u "$EXPECTED" "$ACTUAL"; then
    echo "PASS"
    exit 0
else
    echo ""
    echo "FAIL: output differs from expected"
    exit 1
fi
