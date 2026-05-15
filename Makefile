# =============================================================================
# Makefile — Void Linux RAM Boot
#
# Dependências:
#   nasm, gcc (i686-elf-gcc ou gcc -m32), ld, dd, objcopy
#
# No Void Linux:
#   xbps-install nasm gcc
# =============================================================================

# --- Configuração -----------------------------------------------------------

# Dispositivo do pendrive (CUIDADO! dd vai sobrescrever tudo)
# Descubra com: lsblk
PENDRIVE ?= /dev/sdX

# Tamanho do kernel32 em setores (deve coincidir com KERNEL32_SECTORS no stage1.asm)
KERNEL32_SECTORS = 200

# Tamanho do rootfs em setores — calcule com:
#   ROOTFS_SECTORS=$(( $(du -sb /seu/rootfs | cut -f1) / 512 + 1 ))
ROOTFS_SECTORS ?= 0

# Onde está o rootfs no seu sistema (para o dump)
ROOTFS_PATH ?= /

# Onde está o vmlinuz do Void (será copiado pro pendrive também)
VMLINUZ_PATH ?= /boot/vmlinuz

# --- Toolchain --------------------------------------------------------------
NASM    = nasm
CC      = gcc
LD      = ld
OBJCOPY = objcopy

# Flags pra código 32-bit freestanding
CFLAGS32 = -m32 -ffreestanding -fno-stack-protector -fno-pic \
           -fno-builtin -nostdlib -O2 \
           -DROOTFS_SECTORS=$(ROOTFS_SECTORS) \
           -Wall -Wextra

LDFLAGS32 = -m elf_i386 -T kernel32.ld --oformat binary

# --- Targets ----------------------------------------------------------------

.PHONY: all clean install check-rootfs-size

all: stage1.bin kernel32.bin longmode_entry.bin

# Stage 1: assembly puro → 512 bytes exatos
stage1.bin: stage1.asm
	$(NASM) -f bin \
	        -D KERNEL32_SECTORS=$(KERNEL32_SECTORS) \
	        -o $@ $<
	@size=$$(wc -c < $@); \
	if [ $$size -ne 512 ]; then \
	    echo "ERRO: stage1.bin tem $$size bytes (precisa ser 512!)"; exit 1; \
	fi
	@echo "[OK] stage1.bin: 512 bytes"

# Kernel32 entry: assembly → objeto ELF
kernel32_entry.o: kernel32_entry.asm
	$(NASM) -f elf32 -o $@ $<

# Kernel32 main: C → objeto ELF
kernel32_main.o: kernel32_main.c
	$(CC) $(CFLAGS32) -c -o $@ $<

# Linka kernel32 e extrai binário flat
kernel32.elf: kernel32_entry.o kernel32_main.o kernel32.ld
	$(LD) $(LDFLAGS32) -o $@ kernel32_entry.o kernel32_main.o

kernel32.bin: kernel32.elf
	$(OBJCOPY) -O binary $< $@
	@size=$$(wc -c < $@); \
	max=$$(($(KERNEL32_SECTORS) * 512)); \
	echo "[OK] kernel32.bin: $$size bytes (max $$max)"; \
	if [ $$size -gt $$max ]; then \
	    echo "ERRO: kernel32.bin muito grande! Aumente KERNEL32_SECTORS"; exit 1; \
	fi

# Longmode entry: assembly puro
longmode_entry.bin: longmode_entry.asm
	$(NASM) -f bin -o $@ $<
	@echo "[OK] longmode_entry.bin: $$(wc -c < $@) bytes"

# --- Linker script ----------------------------------------------------------
kernel32.ld:
	@cat > $@ << 'EOF'
ENTRY(_start)
SECTIONS {
    . = 0x10000;
    .text   : { *(.text)   }
    .rodata : { *(.rodata) }
    .data   : { *(.data)   }
    .bss    : { *(.bss)    }
}
EOF

# --- Calcula tamanho do rootfs ----------------------------------------------
check-rootfs-size:
	@echo "Calculando tamanho do rootfs em $(ROOTFS_PATH)..."
	@bytes=$$(du -sb $(ROOTFS_PATH) | cut -f1); \
	sectors=$$(( (bytes + 511) / 512 )); \
	echo "Bytes:   $$bytes"; \
	echo "Setores: $$sectors"; \
	echo ""; \
	echo "Use: make ROOTFS_SECTORS=$$sectors install"

# --- Instala no pendrive ----------------------------------------------------
# Layout do pendrive:
#   Setor 0:                  stage1.bin      (512 bytes)
#   Setores 1..127:           kernel32.bin    (~63KB)
#   Setor 128:                longmode_entry  (stub 64-bit)
#   Setor 160...:             vmlinuz do Void
#   Setor 2048+:              rootfs dump
VMLINUZ_LBA   = 160
ROOTFS_LBA    = 2048   # 1MB offset do início, alinhamento seguro

install: all
	@if [ "$(PENDRIVE)" = "/dev/sdX" ]; then \
	    echo "ERRO: defina PENDRIVE=/dev/sdX (ex: /dev/sdb)"; exit 1; \
	fi
	@if [ "$(ROOTFS_SECTORS)" = "0" ]; then \
	    echo "ERRO: defina ROOTFS_SECTORS. Use: make check-rootfs-size"; exit 1; \
	fi
	@echo "=== ATENÇÃO: isso vai DESTRUIR $(PENDRIVE) ==="
	@echo "Ctrl+C pra cancelar, Enter pra continuar..."
	@read _

	@echo "[1/5] Escrevendo stage1 (MBR)..."
	dd if=stage1.bin of=$(PENDRIVE) bs=512 count=1 conv=notrunc

	@echo "[2/5] Escrevendo kernel32..."
	dd if=kernel32.bin of=$(PENDRIVE) bs=512 seek=1 conv=notrunc

	@echo "[3/5] Escrevendo longmode stub..."
	dd if=longmode_entry.bin of=$(PENDRIVE) bs=512 seek=128 conv=notrunc

	@echo "[4/5] Escrevendo vmlinuz ($(VMLINUZ_PATH))..."
	dd if=$(VMLINUZ_PATH) of=$(PENDRIVE) bs=512 seek=$(VMLINUZ_LBA) conv=notrunc

	@echo "[5/5] Copiando rootfs ($(ROOTFS_PATH)) como CPIO → isso pode demorar..."
	cd $(ROOTFS_PATH) && find . -depth | cpio -H newc -o | dd of=$(PENDRIVE) bs=512 seek=$(ROOTFS_LBA) conv=notrunc

# --- Limpeza ----------------------------------------------------------------
clean:
	rm -f *.bin *.elf *.o sysld.ld
