#include <stddef.h>
#include <stdint.h>

#define PAGETABLE_BASE  0x100000UL
#define ROOTFS_DST      0x200000UL
#define VMLINUZ_DST     0x1000000UL

#define KERNEL32_SECTORS 127
#define ROOTFS_START_LBA (1 + KERNEL32_SECTORS)
#define VMLINUZ_LBA 160
#define VMLINUZ_SECTORS 512

#ifndef ROOTFS_SECTORS
#define ROOTFS_SECTORS (4 * 1024 * 1024)
#endif

static inline void outb(uint16_t port, uint8_t val)
{
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}

static inline uint8_t inb(uint16_t port)
{
    uint8_t val;
    __asm__ volatile("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

static uint16_t* vga = (uint16_t*)0xB8000;
static int vga_col = 0, vga_row = 0;

static void vga_putc(char c)
{
    if (c == '\n') { vga_col = 0; vga_row++; return; }
    vga[vga_row * 80 + vga_col] = (uint16_t)(0x0F00 | (uint8_t)c);
    if (++vga_col >= 80) { vga_col = 0; vga_row++; }
}

static void print(const char* s)
{
    while (*s) vga_putc(*s++);
}

static void print_hex(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    print("0x");
    for (int i = 28; i >= 0; i -= 4)
        vga_putc(hex[(v >> i) & 0xF]);
}

/* ATA PIO - leitura do pendrive, se não funcionar (raro, BIOS emula como ATA) é necessário INT13 trampoline em real mode */

#define ATA_DATA        0x1F0
#define ATA_SECTOR_CNT  0x1F2
#define ATA_LBA_LO      0x1F3
#define ATA_LBA_MID     0x1F4
#define ATA_LBA_HI      0x1F5
#define ATA_DRIVE_HEAD  0x1F6
#define ATA_CMD         0x1F7
#define ATA_STATUS      0x1F7
#define ATA_CMD_READ    0x20

static void ata_wait_ready(void) { while (inb(ATA_STATUS) & 0x80); }
static void ata_wait_drq(void)   { while (!(inb(ATA_STATUS) & 0x08)); }

static void ata_read_sectors(uint32_t lba, uint32_t count, void* dst)
{
    uint16_t* buf = (uint16_t*)dst;
    while (count > 0) {
	uint8_t n = (count > 255) ? 255 : (uint8_t)count;

	ata_wait_ready();
	outb(ATA_DRIVE_HEAD, 0xE0 | ((lba >> 24) & 0x0F));
	outb(ATA_SECTOR_CNT, n);
	outb(ATA_LBA_LO, (uint8_t)(lba));
	outb(ATA_LBA_MID, (uint8_t)(lba >> 8));
	outb(ATA_LBA_HI, (uint8_t)(lba >> 16));
	outb(ATA_CMD, ATA_CMD_READ);

	for (uint8_t i = 0; i < n; i++) {
	    ata_wait_drq();
	    for (int j = 0; j < 256; j++) {
		uint16_t w;
		__asm__ volatile("inw %1, %0" : "=a"(w) : "Nd"((uint16_t)ATA_DATA));
		*buf++ = w;
	    }
	}

	lba += n;
	count -= n;
    }
}

static void setup_paging(void)
{
    uint8_t *pt_area = (uint8_t *)PAGETABLE_BASE;
    for (int i = 0; i < 4 * 4096; i++) pt_area[i] = 0;

    uint64_t *pml4 = (uint64_t *)(PAGETABLE_BASE);
    uint64_t *pdpt = (uint64_t *)(PAGETABLE_BASE + 0x1000);
    uint64_t *pd   = (uint64_t *)(PAGETABLE_BASE + 0x2000);

    pml4[0] = (PAGETABLE_BASE + 0x1000) | 3;

    for (int i = 0; i < 4; i++)
        pdpt[i] = (PAGETABLE_BASE + 0x2000 + i * 0x1000) | 3;

    uint64_t *cur_pd = pd;
    for (int pdpt_i = 0; pdpt_i < 4; pdpt_i++) {
        cur_pd = (uint64_t *)(PAGETABLE_BASE + 0x2000 + pdpt_i * 0x1000);
        for (int i = 0; i < 512; i++) {
            uint64_t phys = ((uint64_t)pdpt_i << 30) | ((uint64_t)i << 21);
            cur_pd[i] = phys | 0x83;
        }
    }
}

typedef struct {
    uint16_t limit;
    uint32_t base;
} __attribute__((packed)) GDTDescriptor;

static uint64_t gdt64[3];
static GDTDescriptor gdt64_desc;

static void setup_gdt64(void)
{
    gdt64[0] = 0;
    gdt64[1] = 0x00AF9A000000FFFFULL;
    gdt64[2] = 0x00CF92000000FFFFULL;

    gdt64_desc.limit = sizeof(gdt64) - 1;
    gdt64_desc.base  = (uint32_t)(uintptr_t)gdt64;
}

static void __attribute__((noreturn)) jump_to_longmode(uint64_t entry64)
{
    __asm__ volatile("mov %0, %%cr3" : : "r"((uint32_t)PAGETABLE_BASE));

    uint32_t cr4;
    __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
    cr4 |= (1 << 5);
    __asm__ volatile("mov %0, %%cr4" : : "r"(cr4));

    __asm__ volatile(
        "mov $0xC0000080, %%ecx\n"
        "rdmsr\n"
        "or $0x100, %%eax\n"
        "wrmsr\n"
        : : : "eax", "ecx", "edx"
    );

    uint32_t cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    cr0 |= (1u << 31);
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0));

    __asm__ volatile("lgdt %0" : : "m"(gdt64_desc));

    uint32_t entry32 = (uint32_t)entry64;
    __asm__ volatile(
        "push $0x08\n"
        "push %0\n"
        "retf\n"
        : : "r"(entry32)
    );

    __builtin_unreachable();
}

static void copy_vmlinuz(void)
{
    print("[kernel32] Copiando vmlinuz... LBA =");
    print_hex(VMLINUZ_LBA);
    print(" setores=");
    print_hex(VMLINUZ_SECTORS);
    print("\n");

    uint8_t* dst = (uint8_t*)VMLINUZ_DST;
    uint32_t lba = VMLINUZ_LBA;
    uint32_t remaining = VMLINUZ_SECTORS;

    while (remaining > 0) {
	uint32_t chunk = (remaining > 255) ? 255 : remaining;
	ata_read_sectors(lba, chunk, dst);
	dst += chunk * 512;
	lba += chunk;
	remaining -= chunk;
    }
    print("[kernel32] vmlinuz OK!\n");
}

void kmain32(void)
{
    for (int i = 0; i < 80 * 25; i++) vga[i] = 0x0700;
    vga_col = 0; vga_row = 0;

    print("[kernel32] Protected mode OK\n");

    print("[kernel32] Copiando rootfs... LBA=");
    print_hex(ROOTFS_START_LBA);
    print(" setores=");
    print_hex(ROOTFS_SECTORS);
    print("\n");

    uint8_t *dst = (uint8_t *)ROOTFS_DST;
    uint32_t lba = ROOTFS_START_LBA;
    uint32_t remaining = ROOTFS_SECTORS;

    while (remaining > 0) {
        uint32_t chunk = (remaining > 255) ? 255 : remaining;
        ata_read_sectors(lba, chunk, dst);
        dst       += chunk * 512;
        lba       += chunk;
        remaining -= chunk;

        if (((lba - ROOTFS_START_LBA) % 65536) == 0) print(".");
    }
    print("\n[kernel32] Rootfs OK! Base: ");
    print_hex(ROOTFS_DST);
    print("\n");

    copy_vmlinuz();
    
    print("[kernel32] Configurando paging + GDT...\n");
    setup_paging();
    setup_gdt64();
    print("[kernel32] Saltando para Long Mode...\n");

    #define LONGMODE_STUB  0x180000UL
    jump_to_longmode(LONGMODE_STUB);
}
