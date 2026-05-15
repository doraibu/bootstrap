# =============================================================================
# Makefile — Void Linux RAM Boot
# =============================================================================

# Configurações de Disco
PENDRIVE     ?= /dev/sdX
IMAGE        = disk.img
KERNEL32_LBA = 1
LONGMODE_LBA = 128
VMLINUZ_LBA  = 160
ROOTFS_LBA   = 2048

# Parâmetros de compilação
KERNEL32_SECTORS = 200
ROOTFS_PATH      ?= /
VMLINUZ_PATH     ?= /boot/vmlinuz

# Ferramentas
CC      = gcc
LD      = ld
OBJCOPY = objcopy
QEMU    = qemu-system-x86_64

# Flags para 32 bits (Kernel de transição)
CFLAGS32 = -m32 -ffreestanding -fno-stack-protector -fno-pic \
           -fno-builtin -nostdlib -O2 -Wall -Wextra \
           -DROOTFS_SECTORS=4000 # Valor fallback se não definido [cite: 7]

LDFLAGS32 = -m elf_i386 -T kernel32.ld [cite: 6]

.PHONY: all clean run install

all: stage1.bin kernel32.bin longmode_entry.bin

# 1. Stage 1 (MBR)
stage1.bin: bootmgr.s
	$(CC) -m32 -c -o stage1.o $<
	$(LD) -m elf_i386 -Ttext 0x7C00 --oformat binary -o $@ stage1.o
	@# Garante que o arquivo tenha exatamente 512 bytes 
	@truncate -s 512 $@
	@echo "[OK] stage1.bin (512 bytes)"

# 2. Kernel32 (Entry + Main C)
kernel32_entry.o: kernel32e.s
	$(CC) -m32 -c -o $@ $<

kernel32_main.o: kernel32.c
	$(CC) $(CFLAGS32) -c -o $@ $<

kernel32.elf: kernel32_entry.o kernel32_main.o
	$(LD) $(LDFLAGS32) -o $@ $^ 

kernel32.bin: kernel32.elf
	$(OBJCOPY) -O binary $< $@
	@echo "[OK] kernel32.bin"

# 3. Longmode Stub (64-bit)
longmode_entry.bin: longmode_entry.s
	$(CC) -m64 -c -ffreestanding -o longmode_entry.o $<
	$(OBJCOPY) -O binary longmode_entry.o $@
	@echo "[OK] longmode_entry.bin"

# 4. Gerar Imagem para QEMU
$(IMAGE): all
	@echo "Criando imagem de disco..."
	dd if=/dev/zero of=$(IMAGE) bs=1M count=100
	dd if=stage1.bin of=$(IMAGE) conv=notrunc
	dd if=kernel32.bin of=$(IMAGE) seek=$(KERNEL32_LBA) conv=notrunc
	dd if=longmode_entry.bin of=$(IMAGE) seek=$(LONGMODE_LBA) conv=notrunc
	@# Note: vmlinuz e rootfs precisam ser copiados aqui se você quiser testar o boot completo
	@echo "[OK] $(IMAGE) gerada."

# 5. Comandos Úteis
run: $(IMAGE)
	$(QEMU) -drive format=raw,file=$(IMAGE) -serial stdio

clean:
	rm -f *.bin *.elf *.o $(IMAGE) [cite: 15]

install: all
	@echo "Gravando no pendrive $(PENDRIVE)..."
	sudo dd if=stage1.bin of=$(PENDRIVE) bs=512 count=1 conv=notrunc
	sudo dd if=kernel32.bin of=$(PENDRIVE) bs=512 seek=$(KERNEL32_LBA) conv=notrunc
	sudo dd if=longmode_entry.bin of=$(PENDRIVE) bs=512 seek=$(LONGMODE_LBA) conv=notrunc
