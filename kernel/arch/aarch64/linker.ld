/* Linker script for GaoOS on Raspberry Pi 3 (AArch64)
 *
 * RPi firmware loads kernel8.img at 0x80000.
 * .text.boot must be first so _start is at the load address.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x80000;

    /* Boot code first — _start must be at 0x80000 */
    .text.boot : {
        KEEP(*(.text.boot))
    }

    .text : {
        *(.text .text.*)
    }

    .rodata : ALIGN(4096) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4096) {
        *(.data .data.*)
    }

    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    /* Discard unneeded sections */
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
