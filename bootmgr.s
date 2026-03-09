.code16
.section .text
.globl _start

_start:
    xorw %ax, %ax
    movw %ax, %ds

    movb $0x0e, %ah
    movb $'A', %al
    int $0x10

loop:
    jmp loop

.org 510
.word 0xAA55

# FUTURE IMPLEMENTATION TO JUMP TO KERNEL
