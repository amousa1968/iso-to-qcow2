#!/bin/bash
# convert_linux_iso.sh - Convert Linux ISO to QCOW2 VM image
# Run in Linux environment with KVM/QEMU installed
# Usage: ./convert_linux_iso.sh [ubuntu-22.04 | rhel-9 | custom-iso.iso]
# Multi-distro: rhel10/alma9/alma8/suse + more
# Batch: sudo ./convert_linux_iso.sh rhel10 alma9 suse output → 3 QCOW2 





set -e

# --- CONFIGURATION ---
VM_NAME="linux-generic"
ADMIN_USER="cloud-user"
VM_RAM="4096"
VM_CPUS="4"
DISK_SIZE="60G"
ISO_PATH="${1:-ubuntu-22.04-server-amd64.iso}"  # Default Ubuntu Server
CLOUD_IMG_URL="https://cloud-images.ubuntu.com"  # Change for other distros

echo "Linux ISO to QCOW2 Converter - Starting..."

# --- 1. PREREQUISITES CHECK ---
command -v qemu-img >/dev/null 2>&1 || { echo "Install qemu-img first"; exit 1; }
command -v virt-install >/dev/null 2>&1 || sudo apt install -y virtinst libvirt-clients libvirt-daemon-system

# --- 2. DOWNLOAD LINUX ISO (if not provided) ---
if [[ ! -f "$ISO_PATH" ]]; then
    case "${ISO_PATH,,}" in
        ubuntu*)
            ISO_PATH="ubuntu-22.04.4-live-server-amd64.iso"
            wget -O "$ISO_PATH" "https://releases.ubuntu.com/22.04.4/$ISO_PATH" || true
            OS_INFO="ubuntu22.04"
            USER="ubuntu"
            ;;
        rhel10|almalinux10)
            ISO_PATH="AlmaLinux-10.0-x86_64-boot.iso"
            wget -O "$ISO_PATH" "https://repo.almalinux.org/almalinux/10/isos/x86_64/$ISO_PATH"
            OS_INFO="rhel9.0"
            USER="cloud-user"
            ;;
        alma9|rocky9)
            ISO_PATH="AlmaLinux-9.3-x86_64-boot.iso"
            wget -O "$ISO_PATH" "https://repo.almalinux.org/almalinux/9/isos/x86_64/$ISO_PATH"
            OS_INFO="rhel9.0"
            USER="cloud-user"
            ;;
        alma8|rocky8)
            ISO_PATH="AlmaLinux-8.10-x86_64-boot.iso"
            wget -O "$ISO_PATH" "https://repo.almalinux.org/almalinux/8/isos/x86_64/$ISO_PATH"
            OS_INFO="rhel8.0"
            USER="cloud-user"
            ;;
        sles|suse*)
            ISO_PATH="SLE-15-SP6-Server-DVD-x86_64.iso"
            # Manual download from SUSE (registration)
            echo "Download $ISO_PATH from https://download.suse.com manually"
            OS_INFO="sles15"
            USER="root"
            ;;
        rhel*|centos*)
            echo "RHEL/CentOS: Provide subscription ISO"
            OS_INFO="rhel9.0"
            USER="cloud-user"
            ;;
        *)
            if [[ ! -f "$ISO_PATH" ]]; then
                echo "ISO $ISO_PATH not found, download manually"
                exit 1
            fi
            OS_INFO="generic"
            USER="cloud-user"
            ;;
    esac
fi

# --- 3. CREATE QCOW2 DISK ---
echo "Creating $DISK_SIZE QCOW2 disk..."
qemu-img create -f qcow2 "${VM_NAME}.qcow2" "$DISK_SIZE"

# --- 4. CLOUD-INIT PREP (Ubuntu/Debian example) ---
mkdir -p cloud-init
cat > cloud-init/user-data << 'EOF'
#cloud-config
users:
  - name: cloud-user
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... # Your SSH key
    shell: /bin/bash
packages:
  - qemu-guest-agent
  - virt-what
runcmd:
  - systemctl enable qemu-guest-agent
EOF

cat > cloud-init/meta-data << EOF
instance-id: $(uuidgen)
local-hostname: ${VM_NAME}
EOF

# Generate cloud-init ISO
mkisofs -output seed.iso -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 "${VM_NAME}.qcow2"
sudo mkfs.ext4 /dev/nbd0p1
sudo mount /dev/nbd0p1 /mnt
sudo mkdir -p /mnt/nocloud
sudo cp cloud-init/* /mnt/nocloud/
sudo umount /mnt
sudo qemu-nbd --disconnect /dev/nbd0

# --- 5. LAUNCH INSTALL VM ---
echo "Launching Linux install VM... (Connect with virt-viewer or VNC)"
sudo virt-install \
  --name "${VM_NAME}-install" \
  --ram ${VM_RAM} \
  --vcpus ${VM_CPUS} \
--osinfo ${OS_INFO:-ubuntu22.04} \
  --disk path="${VM_NAME}.qcow2",bus=virtio \
  --disk path="$ISO_PATH",device=cdrom \
  --disk path=seed.iso,device=cdrom \
  --network network=default,model=virtio \
  --graphics vnc,listen=0.0.0.0,port=5900 \
  --video qxl \
  --boot uefi \
  --noautoconsole

echo "VM launched!"
echo "Connect: vnc://localhost:5900"
echo "Complete Linux install (cloud-init auto-configures)"
echo "After install/shutdown: QCOW2 ready for cloud deployment!"
echo "Verify: qemu-img info ${VM_NAME}.qcow2"

