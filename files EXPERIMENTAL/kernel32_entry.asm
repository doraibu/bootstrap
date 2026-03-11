[BITS 32]

; =============================================================================
; KERNEL32 — Entry point (ELF32, linkado em 0x10000 via kernel32.ld)
; Chegamos aqui em protected mode 32-bit, flat memory model
; Stack em 0x90000, código em 0x10000
; =============================================================================

section .text
global kernel32_entry

kernel32_entry:
    ; Zera BSS
    extern _bss_start
    extern _bss_end
    mov edi, _bss_start
    mov ecx, _bss_end
    sub ecx, edi
    xor eax, eax
    rep stosb

    ; Chama o kernel32_main escrito em C
    extern kernel32_main
    call kernel32_main

    ; Não deve retornar, mas por segurança:
    cli
.halt:
    hlt
    jmp .halt
