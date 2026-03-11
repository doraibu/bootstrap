[BITS 16]
[ORG 0x7C00]

%ifndef KERNEL32_SECTORS
%define KERNEL32_SECTORS 127
%endif

cli
xor ax, ax
mov ds, ax
mov es, ax
mov ss, ax
mov sp, 0x7C00

mov [boot_drive], dl

mov ax, 0x2401
int 0x15
jc .a20_fallback
jmp .a20_ok

.a20_fallback:
    call a20_keyboard
.a20_ok:

mov si, dap
mov ah, 0x42
mov dl, [boot_drive]
int 0x13
jc disk_error

lgdt [gdt_descriptor]

mov eax, cr0
or  eax, 1
mov cr0, eax

jmp 0x08:.protected_mode

[BITS 32]
.protected_mode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    jmp 0x10000

[BITS 16]

a20_keyboard:
    call .wait_input
    mov al, 0xAD
    out 0x64, al
    call .wait_input
    mov al, 0xD0
    out 0x64, al
    call .wait_output
    in  al, 0x60
    push ax
    call .wait_input
    mov al, 0xD1
    out 0x64, al
    call .wait_input
    pop ax
    or  al, 2
    out 0x60, al
    call .wait_input
    mov al, 0xAE
    out 0x64, al
    call .wait_input
    ret

.wait_input:
    in  al, 0x64
    test al, 2
    jnz .wait_input
    ret

.wait_output:
    in  al, 0x64
    test al, 1
    jz  .wait_output
    ret

disk_error:
    mov si, msg_disk_err
    call print_str
    hlt

print_str:
    mov ah, 0x0E
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .loop
.done:
    ret

boot_drive: db 0

dap:
    db 0x10
    db 0x00
    dw KERNEL32_SECTORS
    dw 0x0000
    dw 0x1000
    dq 1

msg_disk_err: db "DISK ERR", 0

gdt_start:

    dq 0

    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10011010b
    db 11001111b
    db 0x00

    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b
    db 11001111b
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_star

; =============================================================================
; Padding e assinatura de boot (obrigatório: 0xAA55 no byte 510-511)
; =============================================================================
times 510 - ($ - $$) db 0
dw 0xAA55
