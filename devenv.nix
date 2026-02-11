{ pkgs, ... }:

{
  packages = [
    pkgs.zig
    pkgs.qemu
  ];

  scripts.gaoos-build.exec = ''
    zig build "$@"
  '';

  scripts.gaoos-run.exec = ''
    kernel="''${1:-zig-out/bin/kernel8.img}"
    exec qemu-system-aarch64 \
      -M raspi3b \
      -kernel "$kernel" \
      -serial stdio \
      -display none \
      -no-reboot
  '';

  scripts.gaoos-test.exec = ''
    zig build test "$@"
  '';

  scripts.gaoos-validate.exec = ''
    set -e
    echo "=== GaoOS Toolchain Validation ==="
    echo ""

    echo "1. Zig version: $(zig version)"
    echo "2. QEMU version: $(qemu-system-aarch64 --version | head -1)"
    echo ""

    echo "3. Cross-compiling freestanding test for aarch64..."
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT
    zig build-exe tests/freestanding_test.zig \
      -target aarch64-freestanding-none \
      -fno-lto \
      --name freestanding_test \
      -femit-bin="$tmpdir/test.elf"
    file "$tmpdir/test.elf" | grep -q "ARM aarch64" \
      && echo "   OK: produced aarch64 ELF binary" \
      || { echo "   FAIL: not an aarch64 binary"; exit 1; }

    echo ""
    echo "=== All checks passed ==="
  '';

  enterShell = ''
    export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    echo "GaoOS development environment"
    echo "  zig:  $(zig version)"
    echo "  qemu: $(qemu-system-aarch64 --version | head -1)"
    echo ""
    echo "Commands:"
    echo "  gaoos-build     — build kernel for aarch64"
    echo "  gaoos-run       — boot in QEMU raspi3b"
    echo "  gaoos-test      — run unit tests on host"
    echo "  gaoos-validate  — validate toolchain setup"
  '';
}
