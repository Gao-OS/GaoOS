#!/usr/bin/env bash
# Boot a raw binary on QEMU raspi3b with serial on stdio.
#
# Usage:
#   ./tools/run-qemu.sh [kernel_image] [-- extra_qemu_args...]
#
# Defaults to zig-out/bin/kernel8.img if no argument is given.
# Pass -d int,cpu_reset -D qemu.log for debugging.

set -euo pipefail

KERNEL="${1:-zig-out/bin/kernel8.img}"
shift 2>/dev/null || true

# Skip the -- separator if present
if [[ "${1:-}" == "--" ]]; then
    shift
fi

if [[ ! -f "$KERNEL" ]]; then
    echo "error: kernel image not found: $KERNEL" >&2
    echo "hint: run gaoos-build first" >&2
    exit 1
fi

exec qemu-system-aarch64 \
    -M raspi3b \
    -kernel "$KERNEL" \
    -serial stdio \
    -display none \
    -no-reboot \
    "$@"
