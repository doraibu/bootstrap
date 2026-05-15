.code64
.section .text
.global _start

.equ ROOTFS_DST,     0x200000
.equ VMLINUZ_DST,    0x1000000
.equ VMLINUZ_LBA,    160
.equ VMLINUZ_SECTORS, 512

_start:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov $0x500000, %rsp

    mov $0xB8000, %rdi
    lea msg_start(%rip), %rsi
    call vga_print

    call copy_vmlinuz

    mov $0x90000, %rbx

    movl $0x53726448, 0x202(%rbx)      /* HdrS magic */
    movb $0xFF,       0x210(%rbx)      /* type_of_loader */
    movl $ROOTFS_DST, 0x218(%rbx)      /* ramdisk_image */
    movl $0x20000000, 0x21C(%rbx)      /* ramdisk_size (512MB placeholder) */

    /* Command line */
    mov $0x20000, %rdi
    lea kernel_cmdline(%rip), %rsi
    call copy_cmdline
    movl $0x20000, 0x228(%rbx)         /* cmd_line_ptr */

    /* Jump para o kernel Linux */
    mov $VMLINUZ_DST, %rax
    add $0x200, %rax                   /* pula setup header */
    jmp *%rax

/* ============================================= */
/* VGA Print */
vga_print:
    mov $0x0F, %ah                     /* atributo: branco */
.loop:
    lodsb
    test %al, %al
    jz .done
    stosw
    jmp .loop
.done:
    ret

/* ============================================= */
/* Copia command line */
copy_cmdline:
    mov $0x20000, %rdi
.loop:
    movsb
    cmpb $0, -1(%rsi)
    jne .loop
    ret

/* ============================================= */
/* Carrega vmlinuz */
copy_vmlinuz:
    mov $msg_vmlinuz, %rdi
    call vga_print

    mov $VMLINUZ_DST, %r8              /* destino atual */
    mov $VMLINUZ_LBA, %esi             /* LBA atual */
    mov $VMLINUZ_SECTORS, %ecx         /* setores restantes */

1:
    test %ecx, %ecx
    jz 2f

    mov $255, %edx
    cmp %ecx, %edx
    cmovg %ecx, %edx                   /* n = min(255, remaining) */

    call ata_read_sectors

    mov %edx, %eax
    shl $9, %eax                       /* * 512 */
    add %rax, %r8
    add %rdx, %esi
    sub %rdx, %ecx
    jmp 1b

2:
    mov $msg_vmlinuz_ok, %rdi
    call vga_print
    ret

/* ============================================= */
/* ATA PIO 64-bit - Leitura de setores */
ata_read_sectors:
    push %rax
    push %rcx
    push %rdx
    push %r8
    push %r9

    mov %edx, %r9d                     /* salva n */

    /* Espera BSY = 0 */
.wait_ready:
    inb $0x1F7, %al
    test $0x80, %al
    jnz .wait_ready

    /* Envia comando LBA28 */
    mov %esi, %eax
    outb $0x1F3, %al                   /* LBA low */
    shr $8, %eax
    outb $0x1F4, %al                   /* LBA mid */
    shr $8, %eax
    outb $0x1F5, %al                   /* LBA high */
    shr $8, %eax
    and $0x0F, %al
    or $0xE0, %al                      /* LBA mode + drive 0 */
    outb $0x1F6, %al

    mov %r9b, %al                      /* número de setores */
    outb $0x1F2, %al
    mov $0x20, %al                     /* READ SECTORS */
    outb $0x1F7, %al

    mov %r9d, %ecx                     /* loop por setor */

.read_loop:
    /* Espera DRQ */
.wait_drq:
    inb $0x1F7, %al
    test $0x08, %al
    jz .wait_drq

    /* Lê 256 words (512 bytes) */
    mov $256, %edx
    mov %r8, %rdi
.read_word:
    inw $0x1F0, %ax
    stosw
    dec %edx
    jnz .read_word

    add $512, %r8
    dec %ecx
    jnz .read_loop

    pop %r9
    pop %r8
    pop %rdx
    pop %rcx
    pop %rax
    ret

/* ============================================= */
/* Dados */
.section .rodata

msg_start:      .asciz "=== Long Mode OK - Carregando Void ===\n"
msg_vmlinuz:    .asciz "Carregando vmlinuz da RAM...\n"
msg_vmlinuz_ok: .asciz "vmlinuz carregado com sucesso!\n"

kernel_cmdline:
    .asciz "root=/dev/ram0 rdinit=/sbin/init console=tty0 quiet loglevel=7"
