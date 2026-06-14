VMLINUZ_PATH  ?= /boot/vmlinuz
INITRAMFS_PATH ?= /boot/initramfs.img

IMAGE          = disk.img

CC      = gcc
LD      = ld
OBJCOPY = objcopy
QEMU    = qemu-system-x86_64

CFLAGS32  = -m32 -ffreestanding -fno-stack-protector -fno-pic \
            -fno-builtin -nostdlib -O2 -Wall -Wextra
LDFLAGS32 = -m elf_i386 -T linker.ld

.PHONY: all clean run

all: $(IMAGE)

stage1.bin: bootmgr.s
	$(CC) -m32 -c -o stage1.o $<
	$(LD) -m elf_i386 -Ttext 0x7C00 --oformat binary -o $@ stage1.o
	@truncate -s 512 $@

kernel32.bin: kernel32e.s kernel32.c linker.ld
	$(CC) -m32 -c -o kernel32e.o kernel32e.s
	$(CC) $(CFLAGS32) -c -o kernel32.o kernel32.c
	$(LD) $(LDFLAGS32) -o kernel32.elf kernel32e.o kernel32.o
	$(OBJCOPY) -O binary kernel32.elf $@

longmode_entry.bin: longmode_entry.s $(INITRAMFS_PATH)
	@# Extract size in bytes:
	$(eval INITRAMFS_SIZE_BYTES := $(shell stat -c%s $(INITRAMFS_PATH)))
	@echo "[Makefile] Injecting INITRAMFS size: $(INITRAMFS_SIZE_BYTES) bytes"
	$(CC) -m64 -c -ffreestanding -DROOTFS_SIZE_BYTES=$(INITRAMFS_SIZE_BYTES) -o longmode_entry.o $<
	$(OBJCOPY) -O binary longmode_entry.o $@

$(IMAGE): stage1.bin kernel32.bin longmode_entry.bin $(VMLINUZ_PATH) $(INITRAMFS_PATH)
	@echo "Creating final disk image..."
	dd if=/dev/zero of=$(IMAGE) bs=1M count=128 status=none

	@# Bootloader MBR (0x7C00)
	dd if=stage1.bin of=$(IMAGE) conv=notrunc status=none

	@# Kernel32 (0x10000)
	dd if=kernel32.bin of=$(IMAGE) seek=1 conv=notrunc status=none

	@# 64 bit Longmode Stub (0x180000)
	dd if=longmode_entry.bin of=$(IMAGE) seek=128 conv=notrunc status=none

	@# VMLINUZ (0x1000000)
	dd if=$(VMLINUZ_PATH) of=$(IMAGE) seek=160 conv=notrunc status=none

	@# O INITRAMFS/ROOTFS (0x4000000)
	dd if=$(INITRAMFS_PATH) of=$(IMAGE) seek=2048 conv=notrunc status=none
	@echo "[OK] $(IMAGE) generated successful!"

run: $(IMAGE)
	$(QEMU) -drive format=raw,file=$(IMAGE) -m 4G -cpu host -enable-kvm

clean:
	rm -f *.o *.bin *.elf $(IMAGE)
