# Execution Key Details
# Administrator Password: The script automatically injects Pasword123!into the autounattend.xml.
# D: → virtio-win.iso (drivers)
# E: → post-install-drivers.ps1  
# F: → CloudbaseInitSetup.msi (**F:\CloudbaseInitSetup.msi**)
# Driver Loading: You must still manually click "Load Driver" during the "Where to install?" phase of the Windows GUI to select the VirtIO SCSI driver.
# Final Step: After the VM finishes the automated install and logs you in, Cloudbase-Init will be installed. You should manually open the Cloudbase-Init configuration tool in the VM, select "Run Sysprep", and click Finishto finalize your PCD9 image.
# The PowerShell version ensures native handling of Windows permissions, allows for faster execution using the Windows Hypervisor Platform (WHPX), and automates the creation of an autounattend.xml to handle your local admin and Cloudbase-Init setup.
# Automated Windows-to-qcow2 PowerShell Script
# Run this script in a PowerShell terminal as Administrator. Update the $ISO_PATHvariable to point to your Windows 10 ISO before starting.

#!/bin/bash
# --- CONFIGURATION ---
VM_NAME="windows10_21h2-pcd9"
ADMIN_PASS="Pasword123!"
ISO_PATH="windows10_21h2.iso" # Exact filename match

# 1. Install QEMU & Download Files
echo "Installing QEMU and downloading required drivers..."
winget install -e --id SoftwareFreedomConservancy.QEMU --accept-package-agreements --accept-source-agreements
export PATH="$PATH:/c/Program Files/qemu"

curl -L -o virtio-win.iso "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
curl -L -o CloudbaseInitSetup.msi "https://github.com/cloudbase/cloudbase-init/releases/download/0.9.28/CloudbaseInitSetup_0.9.28_amd64.msi"

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
                    <CommandLine>netsh interface set interface "Ethernet" admin=disable</CommandLine>
                    <Description>Skip Network</Description>
                    <Order>1</Order>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell -ExecutionPolicy Bypass -File "C:\drivers\post-install-drivers.ps1"</CommandLine>
                    <Description>Install VirtIO Drivers</Description>
                    <Order>2</Order>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i C:\CloudbaseInitSetup.msi /qn /l*v C:\cloudbase-init.log' -Wait; netsh advfirewall set allprofiles state off; winrm quickconfig -quiet; Enable-PSRemoting -Force"</CommandLine>
                    <Description>Cloudbase + Firewall OFF + WinRM ON</Description>
                    <Order>3</Order>
                </SynchronousCommand>
            </FirstLogonCommands>
            <OOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
        </component>
    </settings>
</unattend>
EOF

# 3. Create Floppy Image for autounattend.xml (QEMU picks this up as the answer file)
echo "Preparing automation drive..."
qemu-img create -f raw scripts.img 1440K
# Note: On Windows Git Bash, we use -fda in QEMU to point to the XML directly or a virtual floppy.

# 4. Interactive VM Install (Manual: Load VirtIO disk driver during partition screen)
qemu-img create -f qcow2 "${VM_NAME}.qcow2" 120G

echo "=== MANUAL STEPS ==="
echo "1. During 'Where to install Windows' → Load Driver → VirtIO CD (D:) → viostor\\w10\\amd64"
echo "2. VM auto-boots → login Administrator/Pasword123!"
echo "3. Cloudbase Config → Run Sysprep → Shutdown"

echo "Launching VM..."
qemu-system-x86_64.exe \
  -m 6144 -smp 4 -cpu max \
  -accel tcg -snapshot \
  -drive file="${VM_NAME}.qcow2",format=qcow2,if=virtio \
  -cdrom "$ISO_PATH" \
  -drive file="virtio-win.iso",index=2,if=none,id=drive-virtio,readonly=on,media=cdrom \
  -device ide-cd,bus=ide.1,drive=drive-virtio \
  -drive file="post-install-drivers.ps1",index=3,if=none,id=drive-drivers,readonly=on,media=cdrom \
  -device ide-cd,bus=ide.2,drive=drive-drivers \
  -drive file="CloudbaseInitSetup.msi",index=4,if=none,id=drive-cloudbase,readonly=on,media=cdrom \
  -device ide-cd,bus=ide.3,drive=drive-cloudbase \
  -drive file="autounattend.xml",if=floppy,format=raw,readonly=on \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -vga qxl -boot menu=on,order=d

echo ""
echo "=== POST-SYSPREP GOLDEN IMAGE ==="
echo "1. Copy ${VM_NAME}.qcow2 → /pcd9/inventories/windows10_21h2-pcd9.qcow2"
echo "2. Compress: qemu-img convert -O qcow2 -c ${VM_NAME}.qcow2 golden-image.qcow2"
echo "3. Upload to image registry" 
read -p "Press Enter after sysprep complete..."
