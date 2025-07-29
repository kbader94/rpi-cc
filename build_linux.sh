#!/bin/bash
set -e

# === Configuration ===
ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"
DEFCONFIG="bcm2711_defconfig"
DEFCONFIG_URL="https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.6.y/arch/$ARCH/configs/$DEFCONFIG"
KERNEL_REPO="https://github.com/torvalds/linux.git"
KERNEL_BRANCH="fifo_control"
KERNEL_NAME="custom-kernel"

# === Mount paths (default to /tmp if not specified) ===
BOOT_MOUNT="${1:-/tmp/boot}"
ROOT_MOUNT="${2:-/tmp/root}"

# Create mount points if they don't exist
mkdir -p "$BOOT_MOUNT"
mkdir -p "$ROOT_MOUNT"

echo "[*] Using BOOT_MOUNT=$BOOT_MOUNT"
echo "[*] Using ROOT_MOUNT=$ROOT_MOUNT"

# === Clone kernel ===
if [ ! -d "linux" ]; then
  echo "[*] Cloning Linux kernel source..."
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" linux
  cd linux
else
  cd linux
  git branch "$KERNEL_BRANCH" 
 git pull 
fi

# === Ensure defconfig is present ===
if [ ! -f "arch/$ARCH/configs/$DEFCONFIG" ]; then
  echo "[*] Downloading missing defconfig from Raspberry Pi kernel repo..."
  curl -L "$DEFCONFIG_URL" -o "arch/$ARCH/configs/$DEFCONFIG"
fi


# === Install dependencies ===
sudo apt install -y bc bison flex libssl-dev make

# === Configure ===
echo "[*] Configuring kernel..."
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE $DEFCONFIG

# Optional: Add local version to distinguish custom build
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-custom"/' .config || \
  echo 'CONFIG_LOCALVERSION="-custom"' >> .config

# === Build ===
echo "[*] Building kernel, modules, and dtbs..."
make -j$(nproc) ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE Image.gz modules dtbs

# === Install modules ===
echo "[*] Installing modules to $ROOT_MOUNT..."
sudo make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE INSTALL_MOD_PATH="$ROOT_MOUNT" modules_install

# === Install kernel image and DTBs ===
echo "[*] Installing kernel image and DTBs to $BOOT_MOUNT..."

# Backup existing kernel image if present
if [ -f "$BOOT_MOUNT/$KERNEL_NAME.img" ]; then
  sudo cp "$BOOT_MOUNT/$KERNEL_NAME.img" "$BOOT_MOUNT/${KERNEL_NAME}-backup.img"
fi

# Copy kernel image and device trees
sudo cp "arch/$ARCH/boot/Image" "$BOOT_MOUNT/$KERNEL_NAME.img"
sudo cp arch/$ARCH/boot/dts/broadcom/*.dtb "$BOOT_MOUNT/"

# Copy overlays if present
if [ -d arch/$ARCH/boot/dts/overlays ]; then
  sudo mkdir -p "$BOOT_MOUNT/overlays"
  sudo cp arch/$ARCH/boot/dts/overlays/*.dtb* "$BOOT_MOUNT/overlays/"
  [ -f arch/$ARCH/boot/dts/overlays/README ] && sudo cp arch/$ARCH/boot/dts/overlays/README "$BOOT_MOUNT/overlays/"
fi

# === Update config.txt ===
CONFIG_TXT="$BOOT_MOUNT/config.txt"
if grep -q "^kernel=" "$CONFIG_TXT"; then
  sudo sed -i "s|^kernel=.*|kernel=$KERNEL_NAME.img|" "$CONFIG_TXT"
else
  echo "kernel=$KERNEL_NAME.img" | sudo tee -a "$CONFIG_TXT" > /dev/null
fi

echo "[+] Kernel build and installation complete."
echo "[+] Boot partition: $BOOT_MOUNT"
echo "[+] Root partition: $ROOT_MOUNT"
