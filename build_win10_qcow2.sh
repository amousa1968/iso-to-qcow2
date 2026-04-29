#!/bin/bash
# build_win10_qcow2.sh - Updated with enhanced OOBE bypass and Windows compatibility
# Run with: sudo ./build_win10_qcow2.sh (on Linux/WSL)

set -euo pipefail

# ----- Configuration -----
ISO_PATH="windows10_21h2.iso"
OUTPUT_QCOW2="windows10-template.qcow2"
DISK_SIZE="120G"
RAM_MB="8192"
CPU_CORES="6"
ADMIN_PASSWORD="Password123!"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo_color() {
    echo -e "${2}${1}${NC}"
}

# ----- Find QEMU installation -----
QEMU_PATH=""
if command -v qemu-system-x86_64 &> /dev/null; then
    QEMU_PATH="qemu-system-x86_64"
elif [ -f "/usr/bin/qemu-system-x86_64" ]; then
    QEMU_PATH="/usr/bin/qemu-system-x86_64"
elif [ -f "/usr/local/bin/qemu-system-x86_64" ]; then
    QEMU_PATH="/usr/local/bin/qemu-system-x86_64"
else
    echo_color "ERROR: QEMU not found. Please install QEMU first." "$RED"
    echo "Ubuntu/Debian: sudo apt install qemu-system-x86 qemu-utils genisoimage"
    echo "RHEL/CentOS: sudo yum install qemu-kvm qemu-img genisoimage"
    exit 1
fi

echo_color "Using QEMU: $QEMU_PATH" "$GREEN"

# ----- Create working directory -----
WORK_DIR=$(mktemp -d)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSWERFILE="$WORK_DIR/autounattend.xml"
SETUP_SCRIPT="$WORK_DIR/SetupComplete.ps1"
VIRTIO_WIN_ISO="$SCRIPT_DIR/virtio-win.iso"

echo_color "Working directory: $WORK_DIR" "$CYAN"

# Check for virtio-win.iso
if [ ! -f "$VIRTIO_WIN_ISO" ]; then
    echo_color "NOTE: virtio-win.iso not found. This is optional - Windows will use IDE drivers." "$YELLOW"
    echo "Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    VIRTIO_WIN_ISO=""
fi

# ----- Sanity checks -----
if [ ! -f "$ISO_PATH" ]; then
    echo_color "ERROR: ISO not found at $ISO_PATH" "$RED"
    echo "Current directory: $(pwd)"
    ls -la *.iso 2>/dev/null || echo "No ISO files found"
    exit 1
fi

# ----- 1. Create the QCOW2 disk -----
echo_color "Creating QCOW2 disk: $OUTPUT_QCOW2 ($DISK_SIZE)" "$CYAN"
qemu-img create -f qcow2 "$OUTPUT_QCOW2" "$DISK_SIZE"

# ----- 2. Generate SetupComplete.ps1 script -----
cat > "$SETUP_SCRIPT" << 'EOF'
# SetupComplete.ps1 - Runs at end of Windows setup
Start-Transcript -Path "C:\Windows\Temp\SetupComplete.log"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "SetupComplete script running..." -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Wait for system to be ready
Write-Host "Waiting 60 seconds for system to stabilize..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# Disable Windows Update completely
Write-Host "Disabling Windows Update..." -ForegroundColor Yellow
$services = @("wuauserv", "UsoSvc", "WaaSMedicSvc", "bits", "DoSvc")
foreach ($svc in $services) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "  Disabled: $svc"
}

# Disable updates via registry
Write-Host "Disabling automatic updates via registry..." -ForegroundColor Yellow
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name "AUOptions" -Value 1 -Type DWord -Force

# Prevent automatic reboots
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

# Install Cloudbase-Init
Write-Host "Downloading Cloudbase-Init..." -ForegroundColor Yellow
$url = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$output = "$env:TEMP\CloudbaseInitSetup.msi"
try {
    Invoke-WebRequest -Uri $url -OutFile $output -UseBasicParsing -TimeoutSec 300
    Write-Host "Download completed successfully" -ForegroundColor Green
} catch {
    Write-Host "Failed to download Cloudbase-Init: $_" -ForegroundColor Red
}

if (Test-Path $output) {
    Write-Host "Installing Cloudbase-Init..." -ForegroundColor Yellow
    $msiArgs = "/i `"$output`" /quiet /norestart LOGGINGLEVEL=3 Username=`"Administrator`" RunCloudbaseInitServiceAsLocalSystem=1"
    Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -NoNewWindow
    Write-Host "Cloudbase-Init installed" -ForegroundColor Green
    Start-Sleep -Seconds 10
}

# Configure Administrator account
Write-Host "Configuring Administrator account..." -ForegroundColor Yellow
net user Administrator "Password123!" /logonpasswordchg:no 2>$null
net user Administrator /active:yes 2>$null
Write-Host "Administrator account configured" -ForegroundColor Green

# Disable UAC completely
Write-Host "Disabling UAC..." -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0 -Type DWord -Force

# Configure WinRM
Write-Host "Configuring WinRM..." -ForegroundColor Yellow
winrm quickconfig -q -force 2>$null
winrm set winrm/config/service/auth '@{Basic="true"}' 2>$null
winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>$null

# Configure cloudbase-init
Write-Host "Configuring cloudbase-init..." -ForegroundColor Yellow
$conf = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"
if (Test-Path $conf) {
    $content = Get-Content $conf
    $content = $content -replace 'metadata_services=.*', 'metadata_services=cloudbaseinit.metadata.services.httpservice.HttpService'
    $content | Set-Content $conf
    Add-Content $conf "`ninject_admin_password=true"
    Add-Content $conf "`nadmin_password=Password123!"
    Add-Content $conf "`nallow_reboot=false"
    Add-Content $conf "`nstop_service_on_exit=false"
    Write-Host "Cloudbase-init configured" -ForegroundColor Green
}

# Restart service
Restart-Service CloudbaseInit -ErrorAction SilentlyContinue

# Cleanup before Sysprep
Write-Host "Cleaning up before Sysprep..." -ForegroundColor Yellow
wevtutil el | ForEach-Object { wevtutil cl $_ 2>$null }
powercfg -h off

# Remove pending reboot flags
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name "RebootRequired" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue

# Remove Panther directory (setup logs)
Remove-Item -Path "C:\Windows\Panther\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Cleanup completed" -ForegroundColor Green

# Final wait before Sysprep
Write-Host "Waiting 15 seconds before Sysprep..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# Run Sysprep
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Running Sysprep to generalize the image..." -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

$sysprepPath = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
$sysprepArgs = "/generalize /oobe /shutdown /quiet"

try {
    Write-Host "Executing: $sysprepPath $sysprepArgs" -ForegroundColor Yellow
    $process = Start-Process -FilePath $sysprepPath -ArgumentList $sysprepArgs -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -eq 0) {
        Write-Host "Sysprep completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "Sysprep exited with code: $($process.ExitCode)" -ForegroundColor Red
        
        # Check Sysprep logs
        $sysprepLog = "$env:SystemRoot\System32\Sysprep\Panther\setupact.log"
        if (Test-Path $sysprepLog) {
            Write-Host "Last 20 lines of Sysprep log:" -ForegroundColor Yellow
            Get-Content $sysprepLog -Tail 20
        }
    }
} catch {
    Write-Host "Sysprep execution failed: $_" -ForegroundColor Red
}

Write-Host "SetupComplete finished. VM will now shut down." -ForegroundColor Green
Stop-Transcript
EOF

# ----- 3. Generate autounattend.xml with enhanced OOBE section -----
cat > "$ANSWERFILE" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Type>Primary</Type>
                            <Size>500</Size>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Type>Primary</Type>
                            <Extend>true</Extend>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Format>NTFS</Format>
                            <Label>System</Label>
                            <Active>true</Active>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                            <Format>NTFS</Format>
                            <Label>Windows</Label>
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
                <ProductKey>
                    <Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key>
                </ProductKey>
            </UserData>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <SkipFirstLogonTasks>true</SkipFirstLogonTasks>
                <ProtectYourPC>3</ProtectYourPC>
                <NetworkLocation>Work</NetworkLocation>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>Password123!</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>Password123!</Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Group>Administrators</Group>
                        <DisplayName>Administrator</DisplayName>
                        <Name>Administrator</Name>
                        <Description>Local Administrator</Description>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <Username>Administrator</Username>
                <Password>
                    <Value>Password123!</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>999</LogonCount>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c mkdir C:\Windows\Setup\Scripts</CommandLine>
                    <Order>1</Order>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell.exe -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\SetupComplete.ps1"</CommandLine>
                    <Description>Install Cloudbase-Init and Sysprep</Description>
                    <Order>2</Order>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" /v AUOptions /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64">
            <ComputerName>WIN-TEMPLATE</ComputerName>
        </component>
    </settings>
</unattend>
EOF

# ----- 4. Create a bootable ISO with the answer files -----
echo_color "Creating answer ISO..." "$CYAN"

ISO_DIR="$WORK_DIR/iso_source"
mkdir -p "$ISO_DIR/Windows/Setup/Scripts"

cp "$ANSWERFILE" "$ISO_DIR/autounattend.xml"
cp "$SETUP_SCRIPT" "$ISO_DIR/Windows/Setup/Scripts/SetupComplete.ps1"

ANSWER_ISO="$WORK_DIR/answer.iso"

# Try to create ISO using available tools
ISO_CREATED=false

# Method 1: Try genisoimage
if command -v genisoimage &> /dev/null; then
    echo_color "Creating ISO with genisoimage..." "$YELLOW"
    genisoimage -o "$ANSWER_ISO" -V "AUTORUN" -J -r "$ISO_DIR" 2>/dev/null
    if [ -f "$ANSWER_ISO" ] && [ $(stat -c%s "$ANSWER_ISO") -gt 1024 ]; then
        ISO_CREATED=true
        echo_color "ISO created with genisoimage" "$GREEN"
    fi
fi

# Method 2: Try mkisofs
if [ "$ISO_CREATED" = false ] && command -v mkisofs &> /dev/null; then
    echo_color "Creating ISO with mkisofs..." "$YELLOW"
    mkisofs -o "$ANSWER_ISO" -V "AUTORUN" -J -r "$ISO_DIR" 2>/dev/null
    if [ -f "$ANSWER_ISO" ] && [ $(stat -c%s "$ANSWER_ISO") -gt 1024 ]; then
        ISO_CREATED=true
        echo_color "ISO created with mkisofs" "$GREEN"
    fi
fi

# Method 3: Use xorriso
if [ "$ISO_CREATED" = false ] && command -v xorriso &> /dev/null; then
    echo_color "Creating ISO with xorriso..." "$YELLOW"
    xorriso -as mkisofs -o "$ANSWER_ISO" -V "AUTORUN" -J -r "$ISO_DIR" 2>/dev/null
    if [ -f "$ANSWER_ISO" ] && [ $(stat -c%s "$ANSWER_ISO") -gt 1024 ]; then
        ISO_CREATED=true
        echo_color "ISO created with xorriso" "$GREEN"
    fi
fi

# Fallback: Use folder method
if [ "$ISO_CREATED" = false ]; then
    echo_color "WARNING: Could not create ISO. Using folder method." "$YELLOW"
    ANSWER_ISO="$ISO_DIR"
fi

# ----- 5. Launch QEMU -----
echo ""
echo_color "=========================================" "$CYAN"
echo_color "Starting QEMU installation..." "$CYAN"
echo_color "This will take 30-60 minutes" "$YELLOW"
echo_color "OOBE has been fully bypassed (fix for OOBEZDP/OOBEKEYBOARD)" "$GREEN"
echo_color "Microsoft account login has been bypassed" "$GREEN"
echo_color "Local Administrator account will be used" "$GREEN"
echo_color "=========================================" "$CYAN"
echo ""

# Check if KVM is available
KVM_ACCEL=""
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_ACCEL="-enable-kvm"
    echo_color "KVM acceleration enabled (faster installation)" "$GREEN"
else
    echo_color "KVM not available (installation will be slower)" "$YELLOW"
fi

# Build QEMU command
QEMU_CMD="$QEMU_PATH $KVM_ACCEL -cpu host -smp $CPU_CORES -m $RAM_MB \
    -drive file=$OUTPUT_QCOW2,format=qcow2,if=ide,index=0 \
    -drive file=\"$ISO_PATH\",format=raw,if=ide,index=1,media=cdrom"

# Add answer ISO/folder (using index 2)
if [ -f "$ANSWER_ISO" ]; then
    QEMU_CMD="$QEMU_CMD -drive file=\"$ANSWER_ISO\",format=raw,if=ide,index=2,media=cdrom"
elif [ -d "$ANSWER_ISO" ]; then
    QEMU_CMD="$QEMU_CMD -drive file=fat:ro:\"$ANSWER_ISO\",format=raw,if=ide,index=2,media=cdrom"
fi

# Add virtio-win ISO if available
if [ -n "$VIRTIO_WIN_ISO" ] && [ -f "$VIRTIO_WIN_ISO" ]; then
    QEMU_CMD="$QEMU_CMD -drive file=\"$VIRTIO_WIN_ISO\",format=raw,if=ide,index=3,media=cdrom"
fi

# Windows-optimized flags
QEMU_CMD="$QEMU_CMD -vga qxl -display gtk -machine type=pc -usb -device usb-tablet -rtc base=localtime"

echo_color "Running QEMU..." "$GREEN"
echo_color "Command: $QEMU_CMD" "$GRAY"
echo ""

# Execute QEMU
eval "$QEMU_CMD"

# ----- 6. Wait for completion -----
echo_color "Waiting for Windows installation and Sysprep to finish..." "$CYAN"
while pgrep -f "qemu-system-x86_64" > /dev/null; do
    sleep 10
    echo -n "."
done
echo ""

# ----- 7. Compress the final image -----
echo_color "Compressing final template..." "$CYAN"
TEMPLATE="${OUTPUT_QCOW2%.qcow2}-final-template.qcow2"
qemu-img convert -c -O qcow2 "$OUTPUT_QCOW2" "$TEMPLATE"

# ----- 8. Cleanup -----
echo_color "Cleaning up temporary files..." "$GRAY"
rm -rf "$WORK_DIR"

echo ""
echo_color "=============================================" "$GREEN"
echo_color "SUCCESS!" "$GREEN"
echo_color "=============================================" "$GREEN"
echo_color "Final image: $TEMPLATE" "$WHITE"
echo_color "Administrator password: $ADMIN_PASSWORD" "$WHITE"
echo ""
echo_color "To test the image:" "$YELLOW"
echo_color "$QEMU_PATH -m 4096 -drive file=$TEMPLATE,format=qcow2,if=ide -vga qxl -display gtk" "$WHITE"
echo_color "=============================================" "$GREEN"