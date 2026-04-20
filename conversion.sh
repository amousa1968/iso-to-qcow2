#!/bin/bash

# --- Configuration ---
IMG_NAME="windows10-21h2-base.qcow2"
IMG_SIZE="60G"
WIN_ISO="windows10-21h2.iso" # UPDATE THIS PATH
VIRTIO_ISO_URL="https://fedorapeople.org"
CLOUDBASE_URL="https://cloudbase.it"

# --- 1. System Check ---
echo "Checking for KVM/Virt-manager..."
sudo apt-get update && sudo apt-get install -y qemu-kvm libvirt-daemon-system virtinst wget

# --- 2. Download Artifacts ---
echo "Downloading VirtIO Drivers..."
wget -O virtio-win.iso "$VIRTIO_ISO_URL"

echo "Downloading Cloudbase-init..."
wget -O CloudbaseInitSetup.msi "$CLOUDBASE_URL"

# --- 3. Create Virtual Disk ---
echo "Creating QCOW2 Disk..."
qemu-img create -f qcow2 "$IMG_NAME" "$IMG_SIZE"

# --- 4. Launch Installation ---
echo "Launching VM for Installation..."
echo "!! MANUAL STEPS REQUIRED !!"
echo "1. When prompted for a disk, click 'Load Driver'."
echo "2. Browse the VirtIO CD (usually E: or F:)."
echo "3. Select /NetKVM/w10/amd64 for Network."
echo "4. Select /viostor/w10/amd64 for Disk/Storage."

virt-install \
  --name win10-build \
  --ram 4096 \
  --vcpus 2 \
  --os-variant win10 \
  --disk path="$IMG_NAME",format=qcow2,bus=virtio \
  --disk path="$WIN_ISO",device=cdrom \
  --disk path="virtio-win.iso",device=cdrom \
  --network network=default,model=virtio \
  --graphics spice,listen=0.0.0.0 \
  --video qxl \
  --boot cdrom,hd
