[BITS 16]
[ORG 0x7C00]

%ifndef KERNEL32_SECTORS
%define KERNEL32_SECTORS 127
%endif

; =============================================================================
; STAGE 1 BOOTLOADER
; BIOS carrega esse setor em 0x7C00, executa em real mode (16-bit)
; Objetivo: habilitar A20, entrar em protected mode, carregar Stage 2 (kernel32)
; =============================================================================

; Normaliza segmentos — BIOS pode nos chamar com CS diferente de 0
cli
xor ax, ax
mov ds, ax
mov es, ax
mov ss, ax
mov sp, 0x7C00          ; Stack cresce pra baixo, longe do código

; Salva drive number que a BIOS coloca em DL
mov [boot_drive], dl

; --- Habilita A20 via BIOS (método mais compatível) --------------------------
mov ax, 0x2401
int 0x15
jc .a20_fallback         ; Se falhou, tenta pelo teclado
jmp .a20_ok

.a20_fallback:
    call a20_keyboard
.a20_ok:

; --- Carrega o kernel32 do pendrive ------------------------------------------
; INT 13h Extended (LBA) — lê KERNEL32_SECTORS setores a partir do setor 1
; e coloca em 0x10000 (64KB mark, fora do jeito do BIOS)

mov si, dap              ; DS:SI aponta pro Disk Address Packet
mov ah, 0x42             ; INT 13h Extended Read
mov dl, [boot_drive]
int 0x13
jc disk_error

; --- Monta GDT e entra em Protected Mode -------------------------------------
lgdt [gdt_descriptor]

mov eax, cr0
or  eax, 1               ; Set PE bit
mov cr0, eax

; Far jump limpa pipeline e seta CS pro seletor de código 32-bit (0x08)
jmp 0x08:.protected_mode

; =============================================================================
[BITS 32]
.protected_mode:
    ; Configura todos os segmentos de dados pro seletor 0x10
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000     ; Stack nova em protected mode

    ; Pula pro kernel32 que foi carregado em 0x10000
    jmp 0x10000

; =============================================================================
[BITS 16]

; --- A20 via keyboard controller ---------------------------------------------
a20_keyboard:
    call .wait_input
    mov al, 0xAD         ; Desabilita teclado
    out 0x64, al
    call .wait_input
    mov al, 0xD0         ; Lê output port
    out 0x64, al
    call .wait_output
    in  al, 0x60
    push ax
    call .wait_input
    mov al, 0xD1         ; Escreve output port
    out 0x64, al
    call .wait_input
    pop ax
    or  al, 2            ; Set A20 bit
    out 0x60, al
    call .wait_input
    mov al, 0xAE         ; Reabilita teclado
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

; --- Disk error handler ------------------------------------------------------
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

; =============================================================================
; DADOS
; =============================================================================

boot_drive: db 0

; Disk Address Packet para INT 13h Extended
dap:
    db 0x10              ; Tamanho do DAP
    db 0x00              ; Reservado
    dw KERNEL32_SECTORS  ; Número de setores a ler (definido no Makefile)
    dw 0x0000            ; Offset destino
    dw 0x1000            ; Segmento destino → endereço físico 0x10000
    dq 1                 ; LBA início: setor 1 (logo após o MBR)

msg_disk_err: db "DISK ERR", 0

; =============================================================================
; GDT — Global Descriptor Table
; =============================================================================
gdt_start:
    ; Seletor 0x00 — Null descriptor (obrigatório)
    dq 0

    ; Seletor 0x08 — Code segment, 32-bit, ring 0
    dw 0xFFFF            ; Limit [15:0]
    dw 0x0000            ; Base  [15:0]
    db 0x00              ; Base  [23:16]
    db 10011010b         ; Access: Present, Ring0, Code, Readable
    db 11001111b         ; Flags: 4KB granularity, 32-bit + Limit[19:16]
    db 0x00              ; Base  [31:24]

    ; Seletor 0x10 — Data segment, 32-bit, ring 0
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b         ; Access: Present, Ring0, Data, Writable
    db 11001111b
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1   ; Limite
    dd gdt_start                  ; Base

; =============================================================================
; Padding e assinatura de boot (obrigatório: 0xAA55 no byte 510-511)
; =============================================================================
times 510 - ($ - $$) db 0
dw 0xAA55
