/* User-space linker script for GaoOS
 *
 * Code is loaded at 0x200000 (start of 2MB user block).
 * Stack grows down from top of the block (set by kernel).
 */

ENTRY(_start)

SECTIONS
{
    . = 0x200000;

    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
    }

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(8) {
        *(.data .data.*)
    }

    .bss : ALIGN(8) {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
