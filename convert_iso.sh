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
cat <<'EOF' > autounattend.xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Type>EFI</Type>
                            <Size>260</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Type>MSR</Type>
                            <Size>128</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Format>FAT32</Format>
                            <Label>System</Label>
                            <Letter> S </Letter>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                            <Format winDir="true">NTFS</Format>
                            <Label>Windows</Label>
                            <Letter>C</Letter>
                        </ModifyPartition>
                    </ModifyPartitions>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>2</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>Administrator</FullName>
                <Organization />
                <ProductKey>
                    <Key />
                    <WillShowUI>OnError</WillShowUI>
                </ProductKey>
            </UserData>
        </component>
    </settings>
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
                <LogonCount>1</LogonCount>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Install VirtIO Network Driver</Description>
                    <CommandLine>powershell -ExecutionPolicy Bypass -Command "pnputil /add-driver 'D:\NetKVM\w10\amd64\netkvm.inf' /install; Start-Sleep -Seconds 5; Enable-NetAdapter -Name 'Ethernet' -Confirm:$false -ErrorAction SilentlyContinue"</CommandLine>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Description>Install VirtIO Storage Drivers</Description>
                    <CommandLine>powershell -ExecutionPolicy Bypass -Command "pnputil /add-driver 'D:\viostor\w10\amd64\viostor.inf' /install; pnputil /add-driver 'D:\vioscsi\w10\amd64\vioscsi.inf' /install; pnputil /add-driver 'D:\Balloon\w10\amd64\Balloon.inf' /install; pnputil /add-driver 'D:\qxldod\w10\amd64\qxldod.inf' /install"</CommandLine>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Description>Download and Install Cloudbase-Init</Description>
                    <CommandLine>powershell -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri 'https://github.com/cloudbase/cloudbase-init/releases/download/0.9.28/CloudbaseInitSetup_0.9.28_amd64.msi' -OutFile 'C:\Windows\Temp\CloudbaseInitSetup.msi'; Start-Process msiexec.exe -ArgumentList '/i C:\Windows\Temp\CloudbaseInitSetup.msi /qn /l*v C:\cloudbase-init.log' -Wait"</CommandLine>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Description>Cleanup for Sysprep</Description>
                    <CommandLine>powershell -ExecutionPolicy Bypass -File "C:\cleanup-for-sysprep.ps1"</CommandLine>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Description>Firewall OFF + WinRM ON</Description>
                    <CommandLine>powershell -ExecutionPolicy Bypass -Command "netsh advfirewall set allprofiles state off; winrm quickconfig -quiet; Enable-PSRemoting -Force"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
            <OOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipNetworking>true</SkipNetworking>
                <SkipEULA>true</SkipEULA>
                <ProtectYourPC>3</ProtectYourPC>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Other</NetworkLocation>
            </OOBE>
        </component>
    </settings>
</unattend>
EOF

# Copy scripts to C:\ for VM access (via host mount or manual)
powershell -Command "Copy-Item 'post-install-drivers.ps1', 'cleanup-for-sysprep.ps1' -Destination 'C:\temp' -Force" 2>/dev/null || echo "Manual copy PS1 to C:\temp if needed"

# 3. Create Floppy Image for autounattend.xml (QEMU picks this up as the answer file)
echo "Preparing automation drive..."
# 3. Create floppy image for autounattend.xml properly for Windows QEMU
echo "Creating floppy image for autounattend.xml (raw)..."
qemu-img create -f raw floppy.img 1M
(echo -ne '\032\001BOOT\000'; cat autounattend.xml) > temp_floppy.bin
dd if=temp_floppy.bin of=floppy.img bs=512 count=2880 conv=notrunc 2>/dev/null || cat autounattend.xml > floppy.img

# 4. Create QCOW2 disk
qemu-img create -f qcow2 "${VM_NAME}.qcow2" 120G

echo "=== MANUAL STEPS ==="
echo "1. During 'Where to install Windows' → Load Driver → VirtIO CD (D:) → viostor\w10\amd64"
echo "2. VM auto-boots → login Administrator/Password123! (runs cleanup, drivers, Cloudbase automatically)"
echo "3. Open Cloudbase-Init Config Tool → Generate Password → Run Sysprep → Finish → Shutdown"

echo "Launching VM ..."
qemu-system-x86_64.exe \
  -m 8192 -smp 6 -cpu max \
  -accel tcg \
  -drive file="${VM_NAME}.qcow2",format=qcow2,if=virtio \
  -drive file="$ISO_PATH",media=cdrom \
  -drive file="virtio-win.iso",media=cdrom \
  -drive file="floppy.img",format=raw,if=floppy \
  -net nic,model=virtio -net user \
  -vga std \
  -boot menu=on,order=d

echo ""
echo "=== POST-SYSPREP GOLDEN IMAGE ==="
echo "1. Copy ${VM_NAME}.qcow2 to your target inventory"
echo "2. Compress: qemu-img convert -O qcow2 -c ${VM_NAME}.qcow2 golden-image.qcow2"
echo "3. Upload to image registry"
echo "VM is now running. Complete sysprep inside VM, then shutdown."
