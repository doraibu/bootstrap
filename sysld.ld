/*
 * kernel32.ld — Linker script para o kernel32
 * Código flat binário, carregado em 0x10000
 */

ENTRY(kernel32_entry)

SECTIONS
{
    . = 0x10000;

    .text : {
        /* Entry point primeiro */
        kernel32_entry.o(.text)
        *(.text)
        *(.text.*)
    }

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }

    .data : {
        *(.data)
        *(.data.*)
    }

    .bss : {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        _bss_end = .;
    }

    /* Descarta seções desnecessárias */
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
