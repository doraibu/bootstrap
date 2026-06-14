#include <stddef.h>
#include <stdint.h>

/* Where the 64 bit page tables will live */
#define PAGETABLE_BASE 0x100000UL

/* Structure to load GDT64 */
struct gdt_descriptor {
  uint16_t limit;
  uint32_t base;
} __attribute__((packed));

static uint64_t gdt64[3] __attribute__((aligned(8))) = {
  0x0000000000000000ULL, /* NULL slot */
  0x00AF9A000000FFFFULL, /* 64 bit code (Kernel Mode) */
  0x00CF92000000FFFFULL  /* 64 bit data (Kernel Mode) */
};

static struct gdt_descriptor gdt64_desc;

/* sets up the 4 level paging for long mode */
static void setup_paging(void)
{
  uint64_t *pt_area = (uint64_t *)PAGETABLE_BASE;
  for (int i = 0; i < (6 * 4096) / 8; ++i) {
    pt_area[i] = 0;
  }
  
  uint64_t *pml4 = (uint64_t *)(PAGETABLE_BASE);
  uint64_t *pdpt = (uint64_t *)(PAGETABLE_BASE + 0x1000);

  pml4[0] = ((uint32_t)pdpt) | 3;

  for (int i = 0; i < 4; ++i) {
    uint64_t *pd = (uint64_t *)(PAGETABLE_BASE + 0x2000 + (i * 0x1000));
    pdpt[i] = ((uint32_t)pd) | 3;

    for (int j = 0; j < 512; ++j) {
      uint64_t phys_addr = ((uint64_t)i << 30) | ((uint64_t)j << 21);
      pd[j] = phys_addr | 0x83;
    }
  }
}

static void __attribute__((noreturn)) jump_to_longmode(uint32_t entry64)
{
  __asm__ volatile("mov %0, %%cr3" :: "r"((uint32_t)PAGETABLE_BASE));
  uint32_t cr4;
  __asm__ volatile("mov %%cr4, %0" :: "=r"(cr4));
  cr4 |= (1 << 5);
  __asm__ volatile("mov %0, %%cr4" :: "r"(cr4));

  __asm__ volatile(
		   "mov $0xC0000080, %%ecx\n"
		   "rdmsr\n"
		   "or $0x100, %%eax\n"
		   "wrmsr\n"
		   ::: "eax", "ecx", "edx"
		   );

  uint32_t cr0;
  __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
  cr0 |= (1u << 31);
  __asm__ volatile("mov %0, %%cr0" :: "r"(cr0));
  gdt64_desc.limit = sizeof(gdt64) - 1;
  gdt64_desc.base  = (uint32_t)(uintptr_t)gdt64;
  __asm__ volatile("lgdt %0" : : "m"(gdt64_desc));

  __asm__ volatile(
		   "push $0x08\n"
		   "push %0\n"
		   "retf\n"
		   :: "r"(entry64)
		   );

  __builtin_unreachable();
}

void kmain32(void)
{
  uint16_t *vga = (uint16_t *)0xB8000;
  for (int i = 0; i < 80 * 25; ++i)
    vga[i] = 0x0720;

  vga[0] = 0x0F4C;
  vga[1] = 0x0F4D;

  setup_paging();

  #define LONGMODE_STUB 0x180000UL
  jump_to_longmode(LONGMODE_STUB);
}
