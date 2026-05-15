# =============================================================================
# Makefile — Void Linux RAM Boot (Sintaxe AT&T / GAS)
# =============================================================================

PENDRIVE ?= /dev/sdX

KERNEL32_SECTORS = 200
VMLINUZ_LBA      = 160
ROOTFS_LBA       = 2048
LONGMODE_LBA     = 128

ROOTFS_PATH  ?= /
VMLINUZ_PATH ?= /boot/vmlinuz

# Ferramentas alteradas para o ecossistema GNU
AS      = as
CC      = gcc
LD      = ld
OBJCOPY = objcopy

# Flags para 32 bits
CFLAGS32 = -m32 -ffreestanding -fno-stack-protector -fno-pic \
           -fno-builtin -nostdlib -O2 \
           -DROOTFS_SECTORS=$(ROOTFS_SECTORS) \
           -Wall -Wextra

LDFLAGS32 = -m elf_i386 -T kernel32.ld

.PHONY: all clean install check-rootfs-size

all: stage1.bin kernel32.bin longmode_entry.bin

# Stage 1 (MBR) - Usando GCC para poder passar o -D (Define)
# A sintaxe AT&T no GAS requer que você use .code16 no topo do arquivo .s
stage1.bin: bootmgr.s
	$(CC) -m32 -nostdlib -static -Wl,--oformat,binary \
		-Wa,--defsym,KERNEL32_SECTORS=$(KERNEL32_SECTORS) \
		-Ttext=0x7C00 -o $@ $<
	@size=$$(wc -c < $@); [ $$size -eq 512 ] || { echo "ERRO: stage1.bin deve ter 512 bytes"; exit 1; }
	@echo "[OK] stage1.bin"

# Kernel32 Entry (Assembly AT&T)
kernel32_entry.o: kernel32e.s
	$(AS) --32 -o $@ $<

# Kernel32 Main (C)
kernel32_main.o: kernel32.c
	$(CC) $(CFLAGS32) -c -o $@ $<

# Link Kernel32
kernel32.elf: kernel32_entry.o kernel32_main.o kernel32.ld
	$(LD) $(LDFLAGS32) -o $@ $^

kernel32.bin: kernel32.elf
	$(OBJCOPY) -O binary $< $@
	@echo "[OK] kernel32.bin"

# Longmode Stub (GAS 64-bit)
longmode_entry.bin: longmode_entry.s
	$(CC) -c -m64 -ffreestanding -o longmode_entry.o $<
	$(OBJCOPY) -O binary longmode_entry.o $@
	@echo "[OK] longmode_entry.bin"

check-rootfs-size:
	@bytes=$$(du -sb $(ROOTFS_PATH) | cut -f1); \
	sectors=$$(( (bytes + 511) / 512 )); \
	echo "Bytes:    $$bytes"; \
	echo "Setores: $$sectors"; \
	echo "make ROOTFS_SECTORS=$$sectors install"

install: all
	@if [ "$(PENDRIVE)" = "/dev/sdX" ]; then echo "ERRO: defina PENDRIVE=/dev/sdX"; exit 1; fi
	@if [ "$(ROOTFS_SECTORS)" = "0" ]; then echo "ERRO: defina ROOTFS_SECTORS"; exit 1; fi

	@echo "=== ATENÇÃO: vai apagar $(PENDRIVE) ==="
	@read -p "Pressione Enter para continuar..."

	dd if=stage1.bin         of=$(PENDRIVE) bs=512 count=1 conv=notrunc
	dd if=kernel32.bin       of=$(PENDRIVE) bs=512 seek=1 conv=notrunc
	dd if=longmode_entry.bin of=$(PENDRIVE) bs=512 seek=$(LONGMODE_LBA) conv=notrunc
	dd if=$(VMLINUZ_PATH)    of=$(PENDRIVE) bs=512 seek=$(VMLINUZ_LBA) conv=notrunc

	@echo "[5/5] Copiando rootfs como cpio..."
	cd $(ROOTFS_PATH) && find . -depth | cpio -H newc -o | \
	dd of=$(PENDRIVE) bs=512 seek=$(ROOTFS_LBA) conv=notrunc

	@echo "[OK] Pendrive pronto!"

clean:
	rm -f *.bin *.elf *.o *.img
