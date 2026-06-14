        .code32
        .section .text
        .global kstart

kstart:
	_bss_start
	_bss_end
        mov $_bss_start, %edi
        mov $_bss_end, %ecx
        sub %edi, %ecx
        xor %eax, %eax
        rep stosb

        call kmain32

        cli
halt:
        hlt
        jmp halt
