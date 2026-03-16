#include <stddef.h>
#include <stdint.h>

#define PAGETABLE 0x100000UL
#define ROOTFS 0x200000UL

#define KERNEL32_SECTOR 127
#define ROOTFS_START_LBA (1 + KERNEL32_SECTORS)

static uint16_t* vga = (uint16_t*)0xB8000;
static int vga_col = 0;
static int vga_row = 0;

static void kputc(char c)
{
        if (c == '\n') {
                vga_col = 0;
                vga_row++;
                return;
        }
        vga[vga_row * 80 + vga_col] = (uint16_t)(0x0F00 | (uint8_t)c);
        if (++vga_col >= 80) {
                vga_col = 0;
                vga_row++;
        }
}

static void kprint(const char* s)
{
        while (*s) kputc(*s++);
}

static void kprint_hex(uint32_t v)
{
        static const char hex[] = "0123456789ABCDEF";
        kprint("0x");
        for(int i = 28; i >= 0; i -= 4)
                kputc(hex[(v >> 1) & 0xF]);
}
