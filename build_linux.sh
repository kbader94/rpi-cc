#!/bin/bash
set -e

# === Configuration ===
ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"
DEFCONFIG="bcm2711_defconfig"
DEFCONFIG_URL="https://raw.githubusercontent.com/raspberrypi/linux/rpi-6.17.y/arch/$ARCH/configs/$DEFCONFIG"

UPDATE_SOURCE=0 # set to 1 to fetch latest source
GIT_DEPTH="1"

KERNEL_REPO="https://github.com/raspberrypi/linux.git"
KERNEL_BRANCH="rpi-6.17.y"
KERNEL_NAME="custom-kernel"

# === Mount paths (default to /tmp if not specified) ===
BOOT_MOUNT="${1:-/tmp/boot}"
ROOT_MOUNT="${2:-/tmp/root}"

# === Optional: prompt via dialog/whiptail ===
DIALOG_BIN=""
for c in dialog whiptail; do
  if command -v "$c" >/dev/null 2>&1; then DIALOG_BIN="$c"; break; fi
done

# === Prompt for inputs via dialog ===
if [[ -n "$DIALOG_BIN" ]]; then
  # inputbox wrapper; keeps default on cancel
  prompt_input() {
    local title="$1" prompt="$2" defval="$3" out
    out=$("$DIALOG_BIN" --title "$title" --inputbox "$prompt" 10 70 "$defval" 3>&1 1>&2 2>&3) || return 1
    printf '%s' "$out"
  }
  # REPO
  if out=$(prompt_input "Kernel Repo" "Enter git URL for kernel repository:" "$KERNEL_REPO"); then
    [[ -n "$out" ]] && KERNEL_REPO="$out"
  fi
  # BRANCH (allow empty)
  if out=$(prompt_input "Kernel Branch" "Enter branch/tag (leave empty for default):" "$KERNEL_BRANCH"); then
    KERNEL_BRANCH="$out"
  fi
  # NAME
  if out=$(prompt_input "Kernel Image Name" "Enter kernel image base name (without .img):" "$KERNEL_NAME"); then
    [[ -n "$out" ]] && KERNEL_NAME="$out"
  fi
  # BOOT_MOUNT
  if out=$(prompt_input "Boot Mount" "Path to BOOT partition mount:" "$BOOT_MOUNT"); then
    [[ -n "$out" ]] && BOOT_MOUNT="$out"
  fi
  # ROOT_MOUNT
  if out=$(prompt_input "Root Mount" "Path to ROOT filesystem mount:" "$ROOT_MOUNT"); then
    [[ -n "$out" ]] && ROOT_MOUNT="$out"
  fi
else
  echo "[i] 'dialog'/'whiptail' not found; proceeding with defaults/env/args."
fi

# === Clone kernel ===
if [ ! -d "linux" ]; then
  echo "[*] Cloning Linux kernel source from $KERNEL_REPO"
  if [ -z "$KERNEL_BRANCH" ]; then
    
    if [ "$GIT_DEPTH" -eq "1" ]; then
    	git clone --depth=1 "$KERNEL_REPO" linux
    else
    	git clone "$KERNEL_REPO" linux
    fi
  
  else
    
        if [ "$GIT_DEPTH" -eq "1" ]; then
        	git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" linux
        else
        	git clone --branch "$KERNEL_BRANCH" "$KERNEL_REPO" linux
        fi
  fi
  cd linux
else
    cd linux
    if [ $UPDATE_SOURCE -eq 1 ]; then
      echo "[*] Kernel source already exists"
      echo "[*] Fetching updates from $KERNEL_REPO"
      
      git fetch
      if [ -n "$KERNEL_BRANCH" ]; then
        git switch "$KERNEL_BRANCH"
      fi
    fi
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
make -j"$(nproc)" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE Image.gz modules dtbs

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
if grep -q "^kernel=" "$CONFIG_TXT" 2>/dev/null; then
  sudo sed -i "s|^kernel=.*|kernel=$KERNEL_NAME.img|" "$CONFIG_TXT"
else
  echo "kernel=$KERNEL_NAME.img" | sudo tee -a "$CONFIG_TXT" > /dev/null
fi

echo "[+] Kernel build and installation complete."
echo "[+] Boot partition: $BOOT_MOUNT"
echo "[+] Root partition: $ROOT_MOUNT"
echo "[+] Repo: $KERNEL_REPO"
echo "[+] Branch: ${KERNEL_BRANCH:-<default>}"
echo "[+] Image name: $KERNEL_NAME.img"

