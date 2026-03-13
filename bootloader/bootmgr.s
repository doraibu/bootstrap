        .code16
        .section .text
        .global _start

_start:
        cli
        xor %ax, %ax
        mov %ax, %ds
        mov %ax, %es
        mov %ax, %ss
        mov $0x7C00, %sp

        movb %dl, boot_device

        mov $0x2401, %ax
        int $0x15
        jc a20_fail
        jmp default
        
a20_fail:
        call a20_fallback

a20_fallback:
        in $0x92, %al
        or $0x02, %al
        out %al, $0x92

        call wait_input
        mov $0xD1, %al
        out %al, $0x64

        call wait_input
        mov $0xDF, %al
        out %al, $0x60

        call wait_input
        ret

wait_input:
        in $0x64, %al
        test $0x02, %al
        jnz wait_input
        ret
        
default:
        mov $dap, %si
        mov $0x42, %ah
        movb boot_device, %dl
        int $0x13
        jc disk_fail

        lgdt gdt_descriptor
        mov %cr0, %eax
        or $1, %eax
        mov %eax, %cr0

        ljmp $0x08, $protected_mode

disk_fail:
        movw disk_err, %si
        call print_str
        hlt

print_str:
        mov $0x0E, %ah
loop:
        lodsb
        test %al, %al
        jz done
        int $0x10
        jmp loop
done:
        ret

boot_device:
        .byte 0

disk_err:
        .asciz "[FATAL]: DISK ERROR"

gdt:
        .quad 0
        
        .word 0xFFFF
        .word 0x0000
        .byte 0x00
        .byte 0x9A
        .byte 0xCF
        .byte 0x00
        
        .word 0xFFFF
        .word 0x0000
        .byte 0x00
        .byte 0x92
        .byte 0xCF
        .byte 0x00

gdt_end:
        
dap:
        .byte 0x10
        .byte 0x00
        .word 1
        .word 0x0000
        .word 0x1000
        .quad 1

gdt_descriptor:
        .word gdt_end - gdt - 1
        .long gdt

        
        .code32
protected_mode:
        mov $0x10, %ax
        mov %ax, %ds
        mov %ax, %es
        mov %ax, %ss
        mov %ax, %fs
        mov %ax, %gs
        mov $0x90000, %esp

        jmp $0x10000

        .org 510
        .word 0xAA55
