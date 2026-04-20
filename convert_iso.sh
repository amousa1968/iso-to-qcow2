# Execution Key Details
# Administrator Password: The script automatically injects Pasword123!into the autounattend.xml.
# Cloud-Init Solution: The script mounts the CloudbaseInitSetup.msi as a secondary CD drive. The FirstLogonCommands in the XML triggers a PowerShell command to install it silently (/qn) upon the first login.
# Driver Loading: You must still manually click "Load Driver" during the "Where to install?" phase of the Windows GUI to select the VirtIO SCSI driver.
# Final Step: After the VM finishes the automated install and logs you in, Cloudbase-Init will be installed. You should manually open the Cloudbase-Init configuration tool in the VM, select "Run Sysprep", and click Finishto finalize your PCD9 image.
# The PowerShell version ensures native handling of Windows permissions, allows for faster execution using the Windows Hypervisor Platform (WHPX), and automates the creation of an autounattend.xml to handle your local admin and Cloudbase-Init setup.
# Automated Windows-to-qcow2 PowerShell Script
# Run this script in a PowerShell terminal as Administrator. Update the $ISO_PATHvariable to point to your Windows 10 ISO before starting.

#!/bin/bash
# --- CONFIGURATION ---
VM_NAME="windows10_21h2-pcd9"
ADMIN_PASS="Pasword123!"
ISO_PATH="windows10_21h2.iso" # Ensure ISO is in the same folder

# 1. Install QEMU & Download Files
echo "Installing QEMU and downloading required drivers..."
winget install -e --id SoftwareFreedomConservancy.QEMU --accept-package-agreements --accept-source-agreements
export PATH="$PATH:/c/Program Files/qemu"

curl -L -o virtio-win.iso "https://fedorapeople.org"
curl -L -o CloudbaseInitSetup.msi "https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"

# 2. Create autounattend.xml (Sets Admin password & runs script)
cat <<EOF > autounattend.xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$ADMIN_PASS</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <AutoLogon>
                <Password><Value>$ADMIN_PASS</Value><PlainText>true</PlainText></Password>
                <Enabled>true</Enabled>
                <Username>Administrator</Username>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i E:\CloudbaseInitSetup.msi /qn /l*v C:\cloudbase-init-install.log' -Wait"</CommandLine>
                    <Description>Install Cloudbase-Init from Secondary Drive</Description>
                    <Order>1</Order>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
EOF

# 3. Create Floppy Image for autounattend.xml (QEMU picks this up as the answer file)
echo "Preparing automation drive..."
qemu-img create -f raw scripts.img 1440K
# Note: On Windows Git Bash, we use -fda in QEMU to point to the XML directly or a virtual floppy.

# 4. Create and Start the VM
qemu-img create -f qcow2 "${VM_NAME}.qcow2" 120G

echo "Launching VM. Windows will auto-detect autounattend.xml from the floppy drive."
qemu-system-x86_64 \
  -m 4096 -smp 2 -cpu qemu64 -accel tcg \
  -drive file="${VM_NAME}.qcow2",format=qcow2,if=virtio \
  -cdrom "$ISO_PATH" \
  -drive file=virtio-win.iso,if=ide,media=cdrom,readonly=on \
  -fda autounattend.xml \
  -drive file=CloudbaseInitSetup.msi,if=ide,media=cdrom,readonly=on \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -vga std -boot menu=on,order=d
  
# #!/bin/bash
# # --- CONFIGURATION ---
# VM_NAME="windows10_21h2-pcd9"
# DISK_SIZE="120G"
# ADMIN_PASS="Pasword123!"
# ISO_NAME="windows10_21h2.iso"

# # 1. Path Fix: Convert current directory to absolute Windows path
# BASE_DIR=$(cygpath -w "$(pwd)")
# ISO_PATH="$BASE_DIR\\$ISO_NAME"

# if [ ! -f "$ISO_NAME" ]; then
#     echo "ERROR: $ISO_NAME not found in $(pwd)"
#     exit 1
# fi

# # 2. Setup Tools
# winget install -e --id SoftwareFreedomConservancy.QEMU --accept-package-agreements
# export PATH="$PATH:/c/Program Files/qemu"

# # 3. Downloads (Direct Links)
# [ ! -f "virtio-win.iso" ] && curl -L -o virtio-win.iso "https://fedorapeople.org"
# [ ! -f "CloudbaseInitSetup.msi" ] && curl -L -o CloudbaseInitSetup.msi "https://cloudbase.it"

# # 4. Automation XML
# cat <<EOF > autounattend.xml
# <?xml version="1.0" encoding="utf-8"?>
# <unattend xmlns="urn:schemas-microsoft-com:unattend">
#     <settings pass="oobeSystem">
#         <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
#             <UserAccounts>
#                 <AdministratorPassword><Value>$ADMIN_PASS</Value><PlainText>true</PlainText></AdministratorPassword>
#             </UserAccounts>
#             <AutoLogon>
#                 <Password><Value>$ADMIN_PASS</Value><PlainText>true</PlainText></Password>
#                 <Enabled>true</Enabled>
#                 <Username>Administrator</Username>
#             </AutoLogon>
#             <FirstLogonCommands>
#                 <SynchronousCommand wcm:action="add">
#                     <CommandLine>powershell -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i E:\CloudbaseInitSetup.msi /qn /l*v C:\cloudbase-init.log' -Wait"</CommandLine>
#                     <Order>1</Order>
#                 </SynchronousCommand>
#             </FirstLogonCommands>
#         </component>
#     </settings>
# </unattend>
# EOF

# # 5. Create and Start
# qemu-img create -f qcow2 "${VM_NAME}.qcow2" "$DISK_SIZE"

# echo "Attempting to launch with WHPX acceleration..."
# # The -accel whpx,kernel-irqchip=off is standard, but we add 'tcg' as a fallback
# qemu-system-x86_64 \
#   -m 4G -smp 2 -cpu host \
#   -accel whpx,kernel-irqchip=off -accel tcg \
#   -drive file="${VM_NAME}.qcow2",format=qcow2,if=virtio \
#   -cdrom "$ISO_PATH" \
#   -drive file="$BASE_DIR\\virtio-win.iso",index=3,media=cdrom \
#   -drive file="$BASE_DIR\\autounattend.xml",index=0,if=floppy \
#   -drive file="$BASE_DIR\\CloudbaseInitSetup.msi",index=1,media=cdrom \
#   -net nic,model=virtio -net user \
  # -vga qxl -boot d

