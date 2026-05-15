# =============================================================================
# Makefile — Void Linux RAM Boot
# =============================================================================

PENDRIVE ?= /dev/sdX

KERNEL32_SECTORS = 200
VMLINUZ_LBA      = 160
ROOTFS_LBA       = 2048
LONGMODE_LBA     = 128

ROOTFS_PATH  ?= /
VMLINUZ_PATH ?= /boot/vmlinuz

NASM    = nasm
CC      = gcc
LD      = ld
OBJCOPY = objcopy

CFLAGS32 = -m32 -ffreestanding -fno-stack-protector -fno-pic \
           -fno-builtin -nostdlib -O2 \
           -DROOTFS_SECTORS=$(ROOTFS_SECTORS) \
           -Wall -Wextra

LDFLAGS32 = -m elf_i386 -T kernel32.ld --oformat binary

.PHONY: all clean install check-rootfs-size

all: stage1.bin kernel32.bin longmode_entry.bin

stage1.bin: stage1.asm
	$(NASM) -f bin -D KERNEL32_SECTORS=$(KERNEL32_SECTORS) -o $@ $<
	@size=$$(wc -c < $@); [ $$size -eq 512 ] || { echo "ERRO stage1"; exit 1; }
	@echo "[OK] stage1.bin"

kernel32_entry.o: kernel32_entry.asm
	$(NASM) -f elf32 -o $@ $<

kernel32_main.o: kernel32.c
	$(CC) $(CFLAGS32) -c -o $@ $<

kernel32.elf: kernel32_entry.o kernel32_main.o kernel32.ld
	$(LD) $(LDFLAGS32) -o $@ $^

kernel32.bin: kernel32.elf
	$(OBJCOPY) -O binary $< $@
	@echo "[OK] kernel32.bin"

longmode_entry.bin: longmode_entry.S
	$(CC) -c -m64 -ffreestanding -o longmode_entry.o $<
	$(OBJCOPY) -O binary longmode_entry.o $@
	@echo "[OK] longmode_entry.bin"

check-rootfs-size:
	@bytes=$$(du -sb $(ROOTFS_PATH) | cut -f1); \
	sectors=$$(( (bytes + 511) / 512 )); \
	echo "Bytes: $$bytes"; echo "Setores: $$sectors"; \
	echo "make ROOTFS_SECTORS=$$sectors install"

install: all
	@if [ "$(PENDRIVE)" = "/dev/sdX" ]; then echo "Defina PENDRIVE"; exit 1; fi
	@if [ "$(ROOTFS_SECTORS)" = "0" ]; then echo "Defina ROOTFS_SECTORS"; exit 1; fi

	@echo "=== ATENÇÃO: destruindo $(PENDRIVE) ==="
	@read -p "Enter para continuar..."

	dd if=stage1.bin       of=$(PENDRIVE) bs=512 count=1 conv=notrunc
	dd if=kernel32.bin     of=$(PENDRIVE) bs=512 seek=1 conv=notrunc
	dd if=longmode_entry.bin of=$(PENDRIVE) bs=512 seek=$(LONGMODE_LBA) conv=notrunc
	dd if=$(VMLINUZ_PATH)  of=$(PENDRIVE) bs=512 seek=$(VMLINUZ_LBA) conv=notrunc

	cd $(ROOTFS_PATH) && find . -depth | cpio -H newc -o | \
	dd of=$(PENDRIVE) bs=512 seek=$(ROOTFS_LBA) conv=notrunc

	@echo "[OK] Pendrive pronto!"

clean:
	rm -f *.bin *.elf *.o kernel32.ld longmode_entry.o
