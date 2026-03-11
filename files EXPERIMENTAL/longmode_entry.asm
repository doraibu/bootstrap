[BITS 64]
[ORG 0x180000]

; =============================================================================
; LONGMODE ENTRY STUB
; Chegamos aqui em long mode 64-bit, identity mapped, sem OS
; Stack ainda apontando pra região anterior — precisamos consertar
;
; Objetivo: montar o ambiente mínimo pra executar o /sbin/init do Void
;           que está copiado em RAM a partir de ROOTFS_DST (0x200000)
;
; O rootfs foi copiado RAW do pendrive pra 0x200000.
; Layout esperado no pendrive (e portanto na RAM em 0x200000):
;   É um dump de filesystem ext4 (ou qualquer outro que o Void usa)
;   OU um simples tar/cpio extraído diretamente (mais fácil de fazer)
;
; RECOMENDAÇÃO: use um rootfs em formato CPIO flat (sem compressão)
;   pra facilitar o parsing aqui. O kernel do Void vai montar depois.
; =============================================================================

ROOTFS_DST equ 0x200000

; --- Configura segmentos 64-bit ---
; CS já foi setado pelo far jump do kernel32
; Só precisamos setar os data segments
mov ax, 0x10           ; Seletor de data 64-bit (gdt64[2])
mov ds, ax
mov es, ax
mov fs, ax
mov gs, ax
mov ss, ax
mov rsp, 0x500000      ; Stack nova em 5MB, longe de tudo

; --- Mensagem de debug via VGA -----------------------------------------------
mov rdi, 0xB8000
mov rsi, msg_longmode
call vga_print

; =============================================================================
; Aqui começa o trabalho real de setup do ambiente pra rodar o Void.
;
; O Void Linux precisa de:
;   1. Um filesystem montado como root
;   2. /proc, /sys, /dev montados
;   3. O kernel Linux real carregado OU nós mesmos fazemos o exec do init
;
; ABORDAGEM MAIS REALISTA:
;   O que estamos fazendo É essencialmente o trabalho do bootloader do kernel
;   Linux. O kernel do Void (vmlinuz) deveria ser copiado junto no pendrive
;   e carregado aqui.
;
;   Ou seja, a cadeia completa é:
;   Stage1 → Kernel32 (nosso) → vmlinuz do Void → init do Void
;
;   Nosso "kernel32" não substitui o kernel Linux, ele só prepara a RAM
;   e passa controle pro vmlinuz com os parâmetros certos (como o GRUB faz).
; =============================================================================

; --- Prepara boot_params para o kernel Linux (protocolo Linux Boot) ----------
; O kernel Linux x86 espera uma estrutura boot_params em 0x90000
; com zero-page preenchida

; Por ora: jump pro vmlinuz do Void que foi copiado junto
; O vmlinuz deve estar no pendrive após o rootfs, e copiado pra 0x1000000 (16MB)
; pelo kernel32_main (adicionar isso no C depois)

; Setup mínimo do boot_params (Linux boot protocol v2.x)
mov rax, 0x90000
; magic number
mov dword [rax + 0x202], 0x53726448   ; "HdrS" — header magic
; type_of_loader
mov byte  [rax + 0x210], 0xFF          ; undefined loader
; ramdisk (nosso rootfs na RAM)
mov dword [rax + 0x218], ROOTFS_DST    ; ramdisk_image
; ramdisk size — precisa ser preenchido pelo kernel32 com o tamanho real
; por ora placeholder
mov dword [rax + 0x21C], 0x10000000   ; ~256MB placeholder

; cmd_line_ptr — kernel command line em algum lugar da RAM
mov rax, 0x20000
mov rsi, kernel_cmdline
call copy_cmdline       ; copia pra 0x20000
mov dword [0x90228], 0x20000

; Jump pro vmlinuz (startup_64 entry point)
; O vmlinuz copiado em 0x1000000 tem o entry point no início
; (após o setup header de 512 bytes, o código real começa em +0x200)
mov rax, 0x1000200     ; vmlinuz entry point
jmp rax

; =============================================================================
; Helpers
; =============================================================================

; vga_print: RDI = ptr VGA buffer, RSI = string
vga_print:
    mov ah, 0x0F       ; branco em preto
.loop:
    lodsb
    test al, al
    jz .done
    mov [rdi], ax
    add rdi, 2
    jmp .loop
.done:
    ret

; copy_cmdline: copia kernel_cmdline pra 0x20000
copy_cmdline:
    mov rdi, 0x20000
    mov rsi, kernel_cmdline
.loop:
    movsb
    cmp byte [rsi-1], 0
    jne .loop
    ret

; =============================================================================
; Dados
; =============================================================================

msg_longmode: db "Long mode OK! Carregando vmlinuz...", 0

; Parâmetros do kernel Linux
; root=: montamos o rootfs como ramfs/tmpfs
; rdinit: usa nosso init direto
; quiet: sem spam de boot
kernel_cmdline:
    db "root=/dev/ram0 rdinit=/sbin/init console=tty0 quiet", 0
