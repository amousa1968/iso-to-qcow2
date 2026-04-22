<# Essential Usage Instructions
WHPX Error? If you see a "WHPX: Failed to create partition" error, ensure "Windows Hypervisor Platform" is enabled in Windows Features and your terminal is Administrator.
The "Invisible" Disk: When Windows asks where to install, click Load Driver. Navigate to the VirtIO CD drive (D: or E:) and find viostor\w10\amd64. Once loaded, your qcow2 disk will appear.
Automatic Login: The script configures Windows to log in as Administrator with Pasword123!automatically after the install finishes.
Finalizing for PCD9: After the automatic Cloudbase-Init installation finishes in the background, open the Cloudbase-Init Config Tool inside the VM. Check "Run Sysprep" and "Shutdown", then click Finish. Your .qcow2 file is now a ready-to-use template. #>

# --- CONFIGURATION ---
$VM_NAME = "win10-pcd9"
$DISK_SIZE = "120G"
$ADMIN_PASS = "Pasword123!"
$ISO_PATH = "C:\Users\amousa\Documents\Chef\terraform\iso-to-qcow2\windows10_21h2.iso" # UPDATE THIS

# --- 1. INSTALL TOOLS & ENABLE ACCELERATION ---
# Install QEMU via WinGet
if (!(Get-Command qemu-img -ErrorAction SilentlyContinue)) {
    Write-Host "Installing QEMU..." -ForegroundColor Cyan
    winget install -e --id SoftwareFreedomConservancy.QEMU --accept-package-agreements --accept-source-agreements
    $env:Path += ";C:\Program Files\qemu"
}

# --- 2. DOWNLOAD DRIVERS & CLOUDBASE-INIT ---
$VirtioUrl = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
$CloudInitUrl = "https://github.com/cloudbase/cloudbase-init/releases/download/0.9.28/CloudbaseInitSetup_0.9.28_amd64.msi"

if (!(Test-Path "virtio-win.iso")) { 
    Write-Host "Downloading VirtIO Drivers..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $VirtioUrl -OutFile "virtio-win.iso" 
}
if (!(Test-Path "CloudbaseInitSetup.msi")) { 
    Write-Host "Downloading Cloudbase-Init..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $CloudInitUrl -OutFile "CloudbaseInitSetup.msi" 
}

# --- 3. GENERATE AUTOUNATTEND.XML ---
$XMLContent = @"
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
                    <CommandLine>powershell -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i E:\CloudbaseInitSetup.msi /qn /l*v C:\cloudbase-init.log' -Wait"</CommandLine>
                    <Description>Install Cloudbase-Init</Description>
                    <Order>1</Order>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
"@
$XMLContent | Out-File -FilePath "autounattend.xml" -Encoding utf8

# --- 4. CREATE QCOW2 & BOOT ---
qemu-img create -f qcow2 "$VM_NAME.qcow2" $DISK_SIZE

Write-Host "Launching VM. Note: You MUST manually click 'Load Driver' in setup to see the disk." -ForegroundColor Green
qemu-system-x86_64 `
  -m 4G -smp 2 -cpu host -accel whpx `
  -drive file="$VM_NAME.qcow2",format=qcow2,if=virtio `
  -cdrom "$ISO_PATH" `
  -drive file=virtio-win.iso,index=3,media=cdrom `
  -drive file=autounattend.xml,index=0,if=floppy `
  -drive file=CloudbaseInitSetup.msi,index=1,media=cdrom `
  -net nic,model=virtio -net user `
  -vga qxl -boot d
