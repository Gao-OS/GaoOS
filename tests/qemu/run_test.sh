#!/usr/bin/env bash
# GaoOS QEMU integration test runner
#
# Validates that the kernel boots and produces expected key output markers.
# Uses marker-based checking (not exact diff) because concurrent threads
# interleave UART output non-deterministically.
#
# Usage: ./tests/qemu/run_test.sh [kernel_image]
#
# Exit codes:
#   0 = pass (all markers found)
#   1 = fail (missing markers)
#   2 = build failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KERNEL="${1:-zig-out/bin/kernel8.img}"
TIMEOUT_SEC="${QEMU_TIMEOUT:-15}"

cd "$PROJECT_ROOT"

# Verify QEMU is available
if ! command -v qemu-system-aarch64 &> /dev/null; then
    echo "FAIL: qemu-system-aarch64 not found"
    echo "Install: sudo apt-get install qemu-system-arm"
    exit 2
fi

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

QEMU_EXIT=0
timeout "$TIMEOUT_SEC" qemu-system-aarch64 \
    -M raspi3b \
    -kernel "$KERNEL" \
    -serial stdio \
    -display none \
    -no-reboot \
    2>/dev/null > "$ACTUAL" || QEMU_EXIT=$?

# timeout(1) returns 124 on timeout — distinguish from normal QEMU exit
if [ "$QEMU_EXIT" -eq 124 ]; then
    echo "WARN: QEMU timed out after ${TIMEOUT_SEC}s (output may be incomplete)"
fi

# Key markers that MUST appear in the output (order-independent for
# concurrent thread sections, but each must be present)
MARKERS=(
    # Boot sequence
    "GaoOS v0.2"
    "MMU enabled"
    "Thread 0 (init)"
    "Dropping to EL0"

    # Demo header
    "GaoOS Multi-Runtime Demo"

    # Worker spawning
    "Spawning Worker A"
    "Spawning Worker B"
    "Spawning E-Ink driver"
    "Workers spawned"

    # Worker A
    "[Worker A] hello"
    "[Worker A] allocated frame"
    "[Worker A] sent frame cap"
    "[Worker A] exiting"

    # Worker B (spins until killed)
    "[Worker B] hello"
    "[Worker B] spinning"

    # E-Ink driver
    "[E-Ink] driver starting"
    "[E-Ink] init sequence"
    "SPI CMD: 0x12"        # SW_RESET
    "SPI CMD: 0x01"        # DRIVER_OUTPUT
    "SPI CMD: 0x24"        # WRITE_RAM
    "[E-Ink] writing test pattern"
    "[E-Ink] refresh"
    "SPI CMD: 0x22"        # DISPLAY_UPDATE_CTRL2
    "SPI CMD: 0x20"        # MASTER_ACTIVATION
    "[E-Ink] deep sleep"
    "SPI CMD: 0x10"        # DEEP_SLEEP
    "[E-Ink] driver done"

    # Orchestrator results
    "Orchestrator: received frame"
    "Orchestrator: fault from thread"
    "Cap delegation: OK"
    "Orchestrator: killing Worker B"
    "Thread kill: OK"
    "Fault supervision: OK"
    "Thread reap: OK"
    "All workers done"

    # Kernel exit
    "thread 0 exited via syscall"
    "Returning to kernel idle loop"
)

PASS=true
FAILED=()

# Check for fatal errors first — these indicate silent failures that would
# otherwise be masked by passing marker checks
if grep -qF "FATAL:" "$ACTUAL"; then
    echo "FAIL: test encountered fatal error(s):"
    grep -F "FATAL:" "$ACTUAL" | sed 's/^/  /'
    echo ""
    echo "Actual output:"
    cat "$ACTUAL"
    exit 1
fi

for marker in "${MARKERS[@]}"; do
    if ! grep -qF "$marker" "$ACTUAL"; then
        FAILED+=("$marker")
        PASS=false
    fi
done

# Validate fault supervision count: exactly 3 workers should be accounted for
FAULT_COUNT=$(grep -cF "Orchestrator: fault from thread" "$ACTUAL" || true)
if [ "$FAULT_COUNT" -lt 3 ]; then
    FAILED+=("fault count: expected 3, got $FAULT_COUNT")
    PASS=false
fi

if $PASS; then
    echo "PASS (${#MARKERS[@]} markers verified, $FAULT_COUNT/3 faults)"
    exit 0
else
    echo "FAIL: missing ${#FAILED[@]} of ${#MARKERS[@]} markers:"
    for f in "${FAILED[@]}"; do
        echo "  - \"$f\""
    done
    echo ""
    echo "Actual output:"
    cat "$ACTUAL"
    exit 1
fi
