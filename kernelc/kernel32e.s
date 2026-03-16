        .code32
        .section .text
        .global kstart

kstart:
        extern _bss_start
        extern _bss_end
        mov $_bss_start, %edi
        mov $_bss_end, %ecx
        sub %edi, %ecx
        xor %eax, %eax
        rep stosb

        extern kmain32
        call kmain32

        cli
halt:
        hlt
        jmp halt
