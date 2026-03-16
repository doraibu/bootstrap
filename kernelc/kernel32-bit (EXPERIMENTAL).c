/*
 * kernel32_main.c
 * Roda em protected mode 32-bit (flat, sem OS)
 * Compilar com: gcc -m32 -ffreestanding -fno-stack-protector -nostdlib -O2
 *
 * Mapa de memória que vamos usar:
 *   0x00000500  E820 memory map deixado pelo stage1 (trampoline)
 *   0x00007C00  Stage1 (não precisamos mais, pode ser sobrescrito)
 *   0x00010000  Nós mesmos (kernel32)
 *   0x00090000  Stack
 *   0x00100000  Page tables (PML4, PDPT, PD, PT) — 1MB mark, limpo
 *   0x00200000  Destino do rootfs dump na RAM (2MB mark)
 *               O rootfs vai de 0x200000 até onde precisar
 */

#include <stdint.h>
#include <stddef.h>

/* ===========================================================================
 * Definições de endereços
 * =========================================================================*/
#define PAGETABLE_BASE   0x100000UL   /* Onde colocamos as page tables       */
#define ROOTFS_DST       0x200000UL   /* Onde o rootfs vai ser copiado       */

/* No pendrive, após o stage1 (setor 0) e o kernel32 (setores 1..127),
 * o rootfs começa no setor 128. Ajuste ROOTFS_START_LBA se mudar. */
#define KERNEL32_SECTORS 127
#define ROOTFS_START_LBA (1 + KERNEL32_SECTORS)  /* = 128 */

/* Tamanho do rootfs em setores (512 bytes cada).
 * Você vai preencher isso com: du -s --block-size=512 /seu/rootfs
 * Por ora, deixamos como constante que o Makefile pode overridar */
#ifndef ROOTFS_SECTORS
#define ROOTFS_SECTORS   (4 * 1024 * 1024)   /* 2GB worth de setores = placeholder */
#endif

/* ===========================================================================
 * I/O ports
 * =========================================================================*/
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
    uint8_t val;
    __asm__ volatile("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

/* ===========================================================================
 * VGA text mode — debug output simples
 * =========================================================================*/
static uint16_t *vga = (uint16_t *)0xB8000;
static int vga_col = 0, vga_row = 0;

static void vga_putc(char c) {
    if (c == '\n') { vga_col = 0; vga_row++; return; }
    vga[vga_row * 80 + vga_col] = (uint16_t)(0x0F00 | (uint8_t)c);
    if (++vga_col >= 80) { vga_col = 0; vga_row++; }
}

static void print(const char *s) {
    while (*s) vga_putc(*s++);
}

static void print_hex(uint32_t v) {
    static const char hex[] = "0123456789ABCDEF";
    print("0x");
    for (int i = 28; i >= 0; i -= 4)
        vga_putc(hex[(v >> i) & 0xF]);
}

/* ===========================================================================
 * ATA PIO — leitura do pendrive (LBA28, drive 0 ou drive detectado)
 * Funciona pra pendrives USB quando o BIOS emula como ATA (maioria faz)
 * Se não funcionar no seu notebook, precisamos do INT13 trampoline em real mode
 * =========================================================================*/
#define ATA_DATA        0x1F0
#define ATA_SECTOR_CNT  0x1F2
#define ATA_LBA_LO      0x1F3
#define ATA_LBA_MID     0x1F4
#define ATA_LBA_HI      0x1F5
#define ATA_DRIVE_HEAD  0x1F6
#define ATA_CMD         0x1F7
#define ATA_STATUS      0x1F7
#define ATA_CMD_READ    0x20

static void ata_wait_ready(void) {
    while (inb(ATA_STATUS) & 0x80);  /* BSY bit */
}

static void ata_wait_drq(void) {
    while (!(inb(ATA_STATUS) & 0x08));  /* DRQ bit */
}

/* Lê 'count' setores LBA28 para o buffer dst */
static void ata_read_sectors(uint32_t lba, uint32_t count, void *dst) {
    uint16_t *buf = (uint16_t *)dst;

    while (count > 0) {
        uint8_t n = (count > 255) ? 255 : (uint8_t)count;

        ata_wait_ready();
        outb(ATA_DRIVE_HEAD, 0xE0 | ((lba >> 24) & 0x0F));  /* LBA mode, drive 0 */
        outb(ATA_SECTOR_CNT, n);
        outb(ATA_LBA_LO,  (uint8_t)(lba));
        outb(ATA_LBA_MID, (uint8_t)(lba >> 8));
        outb(ATA_LBA_HI,  (uint8_t)(lba >> 16));
        outb(ATA_CMD, ATA_CMD_READ);

        for (uint8_t i = 0; i < n; i++) {
            ata_wait_drq();
            /* Lê 256 words = 512 bytes = 1 setor */
            for (int j = 0; j < 256; j++) {
                uint16_t w;
                __asm__ volatile("inw %1, %0" : "=a"(w) : "Nd"((uint16_t)ATA_DATA));
                *buf++ = w;
            }
        }

        lba   += n;
        count -= n;
    }
}

/* ===========================================================================
 * Configura page tables para Long Mode
 * Identity map: endereço virtual == endereço físico pra primeiros 4GB
 * Estrutura: PML4 → PDPT → PD (2MB pages, pula PT por simplicidade)
 * =========================================================================*/
static void setup_paging(void) {
    /* Limpa área das page tables (4KB * 4 estruturas = 16KB) */
    uint8_t *pt_area = (uint8_t *)PAGETABLE_BASE;
    for (int i = 0; i < 4 * 4096; i++) pt_area[i] = 0;

    uint64_t *pml4 = (uint64_t *)(PAGETABLE_BASE);
    uint64_t *pdpt = (uint64_t *)(PAGETABLE_BASE + 0x1000);
    uint64_t *pd   = (uint64_t *)(PAGETABLE_BASE + 0x2000);

    /* PML4[0] → PDPT */
    pml4[0] = (PAGETABLE_BASE + 0x1000) | 3;  /* Present + Writable */

    /* PDPT[0..3] → PD (cada PDPT entry cobre 1GB) */
    for (int i = 0; i < 4; i++)
        pdpt[i] = (PAGETABLE_BASE + 0x2000 + i * 0x1000) | 3;

    /* PD: 2MB pages, identity map 0..4GB */
    uint64_t *cur_pd = pd;
    for (int pdpt_i = 0; pdpt_i < 4; pdpt_i++) {
        cur_pd = (uint64_t *)(PAGETABLE_BASE + 0x2000 + pdpt_i * 0x1000);
        for (int i = 0; i < 512; i++) {
            uint64_t phys = ((uint64_t)pdpt_i << 30) | ((uint64_t)i << 21);
            cur_pd[i] = phys | 0x83;  /* Present + Writable + 2MB page (PS bit) */
        }
    }
}

/* ===========================================================================
 * GDT 64-bit
 * =========================================================================*/
typedef struct {
    uint16_t limit;
    uint32_t base;
} __attribute__((packed)) GDTDescriptor;

static uint64_t gdt64[3];
static GDTDescriptor gdt64_desc;

static void setup_gdt64(void) {
    gdt64[0] = 0;                    /* Null */
    gdt64[1] = 0x00AF9A000000FFFFULL; /* 64-bit code: L=1, P=1, DPL=0 */
    gdt64[2] = 0x00CF92000000FFFFULL; /* 64-bit data: P=1, DPL=0, S=1, W=1 */

    gdt64_desc.limit = sizeof(gdt64) - 1;
    gdt64_desc.base  = (uint32_t)(uintptr_t)gdt64;
}

/* ===========================================================================
 * Salto para Long Mode (64-bit)
 * Após setup_paging() e setup_gdt64(), fazemos o salto.
 * O endereço de entrada 64-bit é passado como parâmetro.
 * =========================================================================*/
static void __attribute__((noreturn)) jump_to_longmode(uint64_t entry64) {
    /* Carrega CR3 com PML4 */
    __asm__ volatile("mov %0, %%cr3" : : "r"((uint32_t)PAGETABLE_BASE));

    /* Habilita PAE (CR4.PAE) */
    uint32_t cr4;
    __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
    cr4 |= (1 << 5);
    __asm__ volatile("mov %0, %%cr4" : : "r"(cr4));

    /* Seta EFER.LME via MSR 0xC0000080 */
    __asm__ volatile(
        "mov $0xC0000080, %%ecx\n"
        "rdmsr\n"
        "or $0x100, %%eax\n"  /* LME bit */
        "wrmsr\n"
        : : : "eax", "ecx", "edx"
    );

    /* Habilita paging (CR0.PG) — ativa long mode */
    uint32_t cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    cr0 |= (1u << 31);
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0));

    /* Carrega GDT 64-bit */
    __asm__ volatile("lgdt %0" : : "m"(gdt64_desc));

    /* Far jump pra seletor 0x08 (64-bit code) */
    /* entry64 está nos primeiros 4GB então cast pra 32-bit é seguro aqui */
    uint32_t entry32 = (uint32_t)entry64;
    __asm__ volatile(
        "push $0x08\n"
        "push %0\n"
        "retf\n"
        : : "r"(entry32)
    );

    __builtin_unreachable();
}

/* ===========================================================================
 * Ponto de entrada principal
 * =========================================================================*/
void kernel32_main(void) {
    /* Limpa tela */
    for (int i = 0; i < 80 * 25; i++) vga[i] = 0x0700;
    vga_col = 0; vga_row = 0;

    print("[kernel32] Protected mode OK\n");

    /* --- 1. Copiar rootfs pra RAM ---------------------------------------- */
    print("[kernel32] Copiando rootfs pra RAM... LBA=");
    print_hex(ROOTFS_START_LBA);
    print(", setores=");
    print_hex(ROOTFS_SECTORS);
    print("\n");

    /*
     * ATENÇÃO: ROOTFS_SECTORS deve ser o tamanho real do seu rootfs!
     * Calcule com: find /seu/rootfs | wc -c  ou  du -sb /seu/rootfs
     * depois converta pra setores: bytes / 512 (arredonde pra cima)
     *
     * ATA PIO é lento (~3MB/s), pra 2GB isso é ~10min.
     * Se quiser mais rápido, podemos implementar DMA (UDMA) depois.
     */
    uint8_t *dst = (uint8_t *)ROOTFS_DST;
    uint32_t lba = ROOTFS_START_LBA;
    uint32_t remaining = ROOTFS_SECTORS;

    /* Lê em chunks de 255 setores (~127KB) pra ATA LBA28 */
    while (remaining > 0) {
        uint32_t chunk = (remaining > 255) ? 255 : remaining;
        ata_read_sectors(lba, chunk, dst);
        dst       += chunk * 512;
        lba       += chunk;
        remaining -= chunk;

        /* Progresso básico a cada ~32MB */
        if (((lba - ROOTFS_START_LBA) % 65536) == 0) {
            print(".");
        }
    }

    print("\n[kernel32] Rootfs copiado OK! Base: ");
    print_hex(ROOTFS_DST);
    print("\n");

    /* --- 2. Setup paginação e GDT 64-bit --------------------------------- */
    print("[kernel32] Configurando page tables (identity map 4GB)...\n");
    setup_paging();
    setup_gdt64();
    print("[kernel32] OK! Saltando pra long mode...\n");

    /*
     * O entry point 64-bit é o init do Void na RAM.
     * Após o copy, o rootfs está em ROOTFS_DST com layout real de filesystem.
     * O "entry" aqui é um stub 64-bit (longmode_entry.asm) que vai:
     *   - Setar segments 64-bit
     *   - Montar /proc /sys /dev via syscalls (ou chamar o init direto)
     *
     * Por enquanto, apontamos pro início do rootfs + offset do /sbin/init.
     * Na prática, você vai querer um stub assembly em 64-bit antes do init.
     *
     * STUB 64-bit deve ser colocado em ROOTFS_DST antes do filesystem,
     * ou em um endereço separado (ex: 0x180000).
     */
    #define LONGMODE_STUB  0x180000UL
    jump_to_longmode(LONGMODE_STUB);
}
