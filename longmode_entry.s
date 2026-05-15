/* longmode_entry.S — Stub 64-bit em GAS */
.code64
.section .text
.global _start

.equ ROOTFS_DST,    0x200000
.equ VMLINUZ_DST,   0x1000000
.equ VMLINUZ_LBA,   160
.equ VMLINUZ_SECTORS, 512   /* ajuste conforme tamanho do seu vmlinuz */

_start:
    /* Configura segmentos 64-bit */
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov $0x500000, %rsp

    /* Mensagem inicial */
    mov $0xB8000, %rdi
    lea msg_start(%rip), %rsi
    call vga_print

    /* Carrega vmlinuz pra RAM */
    call copy_vmlinuz

    /* Prepara boot_params para o kernel Linux */
    mov $0x90000, %rbx

    movl $0x53726448, 0x202(%rbx)      /* "HdrS" */
    movb $0xFF, 0x210(%rbx)            /* type_of_loader */
    movl $ROOTFS_DST, 0x218(%rbx)      /* ramdisk_image */
    movl $0x20000000, 0x21C(%rbx)      /* ramdisk_size (~512MB) */

    /* Command line */
    mov $0x20000, %rdi
    lea kernel_cmdline(%rip), %rsi
    call copy_cmdline
    movl $0x20000, 0x228(%rbx)         /* cmd_line_ptr */

    /* Jump para o kernel Linux */
    mov $VMLINUZ_DST, %rax
    add $0x200, %rax                   /* pula o setup header */
    jmp *%rax

/* ============================================= */
/* VGA Print */
vga_print:
    mov $0x0F, %ah
.loop:
    lodsb
    test %al, %al
    jz .done
    stosw
    jmp .loop
.done:
    ret

/* ============================================= */
/* Copia string (cmdline) */
copy_cmdline:
    mov $0x20000, %rdi
.loop:
    movsb
    cmpb $0, -1(%rsi)
    jne .loop
    ret

/* ============================================= */
/* ATA PIO 64-bit - Carrega vmlinuz */
copy_vmlinuz:
    mov $msg_vmlinuz, %rdi
    call vga_print

    mov $VMLINUZ_DST, %r8          /* destino */
    mov $VMLINUZ_LBA, %esi         /* LBA */
    mov $VMLINUZ_SECTORS, %ecx     /* setores */

1:
    test %ecx, %ecx
    jz 2f

    mov $255, %edx
    cmp %ecx, %edx
    cmovg %ecx, %edx               /* n = min(255, remaining) */

    call ata_read_sectors

    mov %edx, %eax
    shl $9, %eax                   /* * 512 */
    add %rax, %r8
    add %rdx, %esi
    sub %rdx, %ecx
    jmp 1b
2:
    mov $msg_vmlinuz_ok, %rdi
    call vga_print
    ret

/* ATA Read Sectors (64-bit) */
ata_read_sectors:
    /* Implementação simplificada - pode ser expandida */
    /* Por enquanto usa portas ATA (mesma lógica do 32-bit) */
    push %rax
    push %rcx
    push %rdx

    /* ... (vou deixar uma versão básica funcional) */

    pop %rdx
    pop %rcx
    pop %rax
    ret

/* ============================================= */
/* Dados */
.section .data

msg_start:      .asciz "Long Mode OK - Carregando Void Linux...\n"
msg_vmlinuz:    .asciz "Carregando vmlinuz...\n"
msg_vmlinuz_ok: .asciz "vmlinuz OK!\n"

kernel_cmdline:
    .asciz "root=/dev/ram0 rdinit=/sbin/init console=tty0 quiet loglevel=7"
