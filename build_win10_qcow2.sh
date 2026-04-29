#!/bin/bash
# build_win10_qcow2.sh - For Git Bash on Windows 11
# Run as Administrator in Git Bash
# Usage: ./build_win10_qcow2.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

echo_color() {
    echo -e "${2}${1}${NC}"
}

# ----- Configuration -----
ISO_PATH="windows10_21h2.iso"
OUTPUT_QCOW2="windows10-template.qcow2"
DISK_SIZE="120G"
RAM_MB="4096"
CPU_CORES="2"
ADMIN_PASSWORD="Password123!"

# ----- Find QEMU installation (Windows paths) -----
QEMU_PATH=""
if command -v qemu-system-x86_64 &> /dev/null; then
    QEMU_PATH="qemu-system-x86_64"
elif [ -f "/c/Program Files/qemu/qemu-system-x86_64.exe" ]; then
    QEMU_PATH="/c/Program Files/qemu/qemu-system-x86_64.exe"
elif [ -f "/c/Program Files (x86)/qemu/qemu-system-x86_64.exe" ]; then
    QEMU_PATH="/c/Program Files (x86)/qemu/qemu-system-x86_64.exe"
else
    echo_color "ERROR: QEMU not found!" "$RED"
    echo_color "Please install QEMU from: https://qemu.weilnetz.de/w64/" "$YELLOW"
    echo_color "After installation, restart Git Bash" "$YELLOW"
    exit 1
fi

echo_color "Using QEMU: $QEMU_PATH" "$GREEN"

# ----- Create working directory -----
WORK_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/qemu_build_$$")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSWERFILE="$WORK_DIR/autounattend.xml"
SETUP_SCRIPT="$WORK_DIR/SetupComplete.ps1"
VIRTIO_WIN_ISO="$SCRIPT_DIR/virtio-win.iso"

echo_color "Working directory: $WORK_DIR" "$CYAN"

# Download virtio-win.iso if not present
if [ ! -f "$VIRTIO_WIN_ISO" ]; then
    echo_color "Downloading virtio-win.iso for better performance..." "$YELLOW"
    curl -L -o "$VIRTIO_WIN_ISO" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" 2>/dev/null || {
        echo_color "WARNING: Could not download virtio-win.iso. Using IDE instead." "$YELLOW"
        VIRTIO_WIN_ISO=""
    }
fi

# ----- Sanity checks -----
if [ ! -f "$ISO_PATH" ]; then
    echo_color "ERROR: ISO not found at $ISO_PATH" "$RED"
    echo_color "Current directory: $(pwd)" "$YELLOW"
    ls -la *.iso 2>/dev/null || echo_color "No ISO files found" "$YELLOW"
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

Start-Sleep -Seconds 15

# Disable Windows Update
Write-Host "Disabling Windows Update..." -ForegroundColor Yellow
$services = @("wuauserv","UsoSvc","WaaSMedicSvc","bits","DoSvc")
foreach ($svc in $services) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}

New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord -Force

# Install Cloudbase-Init
Write-Host "Downloading Cloudbase-Init..." -ForegroundColor Yellow
$url = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$output = "$env:TEMP\CloudbaseInitSetup.msi"
Invoke-WebRequest -Uri $url -OutFile $output -UseBasicParsing -TimeoutSec 300

Write-Host "Installing Cloudbase-Init..." -ForegroundColor Yellow
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$output`" /quiet /norestart LOGGINGLEVEL=3 Username=`"Administrator`" RunCloudbaseInitServiceAsLocalSystem=1" -Wait -NoNewWindow
Start-Sleep -Seconds 5

# Configure Administrator
Write-Host "Configuring Administrator..." -ForegroundColor Yellow
net user Administrator "Password123!" /logonpasswordchg:no 2>$null
net user Administrator /active:yes 2>$null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0 -Type DWord -Force

# Configure cloudbase-init
$conf = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"
if (Test-Path $conf) {
    $content = Get-Content $conf
    $content = $content -replace 'metadata_services=.*', 'metadata_services=cloudbaseinit.metadata.services.httpservice.HttpService'
    $content | Set-Content $conf
    Add-Content $conf "`ninject_admin_password=true"
    Add-Content $conf "`nadmin_password=Password123!"
}

# Cleanup
Remove-Item -Path "C:\Windows\Panther\*" -Recurse -Force -ErrorAction SilentlyContinue

# Run Sysprep
Write-Host "Running Sysprep..." -ForegroundColor Cyan
& "C:\Windows\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet

Write-Host "SetupComplete finished. VM will shut down." -ForegroundColor Green
Stop-Transcript
EOF

# ----- 3. Generate autounattend.xml -----
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
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <SkipFirstLogonTasks>true</SkipFirstLogonTasks>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>Password123!</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
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
                    <Order>2</Order>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64">
            <ComputerName>WIN-TEMPLATE</ComputerName>
        </component>
    </settings>
</unattend>
EOF

# ----- 4. Create answer media -----
echo_color "Creating answer media..." "$CYAN"

ISO_DIR="$WORK_DIR/iso_source"
mkdir -p "$ISO_DIR"
cp "$ANSWERFILE" "$ISO_DIR/autounattend.xml"
cp "$SETUP_SCRIPT" "$ISO_DIR/SetupComplete.ps1"

ANSWER_MEDIA="$ISO_DIR"
echo_color "Using folder as answer media" "$YELLOW"

# ----- 5. Launch QEMU -----
echo ""
echo_color "=========================================" "$CYAN"
echo_color "Starting QEMU installation..." "$CYAN"
echo_color "Mode: TCG Emulation (2-3 hours)" "$YELLOW"
echo_color "=========================================" "$CYAN"
echo ""

# Convert Windows paths to proper format for QEMU
# Use cygpath to convert to Windows format if available
if command -v cygpath &> /dev/null; then
    QEMU_PATH_WIN=$(cygpath -w "$QEMU_PATH")
    OUTPUT_QCOW2_WIN=$(cygpath -w "$OUTPUT_QCOW2")
    ISO_PATH_WIN=$(cygpath -w "$ISO_PATH")
    ANSWER_MEDIA_WIN=$(cygpath -w "$ANSWER_MEDIA")
    if [ -n "$VIRTIO_WIN_ISO" ] && [ -f "$VIRTIO_WIN_ISO" ]; then
        VIRTIO_WIN_ISO_WIN=$(cygpath -w "$VIRTIO_WIN_ISO")
    fi
else
    # Fallback: Use paths as-is but quote them properly
    QEMU_PATH_WIN="$QEMU_PATH"
    OUTPUT_QCOW2_WIN="$OUTPUT_QCOW2"
    ISO_PATH_WIN="$ISO_PATH"
    ANSWER_MEDIA_WIN="$ANSWER_MEDIA"
    if [ -n "$VIRTIO_WIN_ISO" ] && [ -f "$VIRTIO_WIN_ISO" ]; then
        VIRTIO_WIN_ISO_WIN="$VIRTIO_WIN_ISO"
    fi
fi

# Build QEMU command as an array to avoid quoting issues
qemu_args=(
    "-accel" "tcg"
    "-cpu" "qemu64"
    "-smp" "$CPU_CORES"
    "-m" "${RAM_MB}M"
    "-drive" "file=$OUTPUT_QCOW2_WIN,format=qcow2,if=ide,index=0"
    "-drive" "file=$ISO_PATH_WIN,format=raw,if=ide,index=1,media=cdrom"
    "-drive" "file=fat:ro:$ANSWER_MEDIA_WIN,format=raw,if=ide,index=2,media=cdrom"
    "-vga" "qxl"
    "-display" "gtk"
    "-machine" "type=pc"
    "-usb"
    "-device" "usb-tablet"
    "-rtc" "base=localtime"
    "-boot" "order=d"
)

# Add virtio-win ISO if available
if [ -n "$VIRTIO_WIN_ISO" ] && [ -f "$VIRTIO_WIN_ISO" ]; then
    qemu_args+=("-drive" "file=$VIRTIO_WIN_ISO_WIN,format=raw,if=ide,index=3,media=cdrom")
fi

echo_color "Running QEMU..." "$GREEN"
echo -e "Command: ${CYAN}$QEMU_PATH_WIN ${qemu_args[*]}${NC}"
echo ""

# Execute QEMU using array expansion
"$QEMU_PATH_WIN" "${qemu_args[@]}"

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
echo_color "Cleaning up temporary files..." "$CYAN"
rm -rf "$WORK_DIR"

echo ""
echo_color "=============================================" "$GREEN"
echo_color "SUCCESS!" "$GREEN"
echo_color "=============================================" "$GREEN"
echo_color "Final image: $TEMPLATE" "$WHITE"
echo_color "Administrator password: $ADMIN_PASSWORD" "$WHITE"
echo ""
echo_color "To test the image:" "$YELLOW"
echo_color "\"$QEMU_PATH\" -accel tcg -cpu qemu64 -m 4096 -drive file=\"$TEMPLATE\",format=qcow2,if=ide -vga qxl -display gtk" "$WHITE"
echo_color "=============================================" "$GREEN"