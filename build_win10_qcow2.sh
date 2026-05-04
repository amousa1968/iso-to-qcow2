#!/bin/bash
# build_win10_qcow2.sh - For Git Bash on Windows 11 (with OOBE bypass)
# Run as Administrator in Git Bash

set -euo pipefail

# Colors - ALL variables defined
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo_color() {
    echo -e "${2}${1}${NC}"
}

# Configuration
ISO_PATH="windows10_21h2.iso"
OUTPUT_QCOW2="windows10-template.qcow2"
DISK_SIZE="120G"
RAM_MB="4096"
CPU_CORES="2"
ADMIN_PASSWORD="Password123!"

# Find QEMU using short path (8.3 format) to avoid spaces
QEMU_PATH=""
if [ -f "/c/PROGRA~1/qemu/qemu-system-x86_64.exe" ]; then
    QEMU_PATH="/c/PROGRA~1/qemu/qemu-system-x86_64.exe"
elif [ -f "/c/Program Files/qemu/qemu-system-x86_64.exe" ]; then
    QEMU_PATH="/c/Program Files/qemu/qemu-system-x86_64.exe"
else
    echo_color "ERROR: QEMU not found!" "$RED"
    echo_color "Please install QEMU from: https://qemu.weilnetz.de/w64/" "$YELLOW"
    exit 1
fi

echo_color "Using QEMU: $QEMU_PATH" "$GREEN"

# Get script directory and convert to Windows path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Convert Unix path to Windows path using cygpath if available, or manually
if command -v cygpath &> /dev/null; then
    SCRIPT_DIR_WIN=$(cygpath -w "$SCRIPT_DIR")
else
    # Manual conversion: /c/Users/... -> C:\Users\...
    SCRIPT_DIR_WIN=$(echo "$SCRIPT_DIR" | sed 's/^\/c\//C:\\/' | sed 's/\//\\/g')
fi
echo_color "Working directory: $SCRIPT_DIR" "$CYAN"

# Find Windows ISO
if [ ! -f "$ISO_PATH" ]; then
    # Try to find any ISO file
    ISO_PATH=$(ls *.iso 2>/dev/null | head -1)
fi
if [ ! -f "$ISO_PATH" ]; then
    echo_color "ERROR: Windows ISO not found!" "$RED"
    echo_color "Please ensure windows10_21h2.iso is in: $SCRIPT_DIR" "$YELLOW"
    exit 1
fi
# Convert ISO path to Windows format
ISO_PATH_FULL="$(pwd)/$ISO_PATH"
if command -v cygpath &> /dev/null; then
    ISO_PATH_WIN=$(cygpath -w "$ISO_PATH_FULL")
else
    ISO_PATH_WIN=$(echo "$ISO_PATH_FULL" | sed 's/^\/c\//C:\\/' | sed 's/\//\\/g')
fi
echo_color "Windows ISO: $ISO_PATH_WIN" "$GREEN"

OUTPUT_QCOW2="$SCRIPT_DIR/$OUTPUT_QCOW2"
# Convert output path to Windows format
if command -v cygpath &> /dev/null; then
    OUTPUT_QCOW2_WIN=$(cygpath -w "$OUTPUT_QCOW2")
else
    OUTPUT_QCOW2_WIN=$(echo "$OUTPUT_QCOW2" | sed 's/^\/c\//C:\\/' | sed 's/\//\\/g')
fi

# Create working directory using Windows temp
WORK_DIR="/tmp/qemu_build_$$"
mkdir -p "$WORK_DIR"
# Convert to Windows path for QEMU
if command -v cygpath &> /dev/null; then
    WORK_DIR_WIN=$(cygpath -w "$WORK_DIR")
else
    WORK_DIR_WIN=$(echo "$WORK_DIR" | sed 's/^\/tmp\//C:\\Temp\\/' | sed 's/\//\\/g')
fi
echo_color "Temp directory: $WORK_DIR_WIN" "$GRAY"

# ----------------------------------------------------------------------------
# Create SetupComplete.ps1 with OOBE bypass
# ----------------------------------------------------------------------------
SETUP_SCRIPT="$WORK_DIR/SetupComplete.ps1"
cat > "$SETUP_SCRIPT" << 'EOF'
# SetupComplete.ps1 - Bypasses OOBE Windows Update screen
Start-Transcript -Path "C:\Windows\Temp\SetupComplete.log"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "SetupComplete script running..." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Kill OOBE processes if stuck
Get-Process -Name "OOBENetworkConnectionFlow" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "OOBE" -ErrorAction SilentlyContinue | Stop-Process -Force

# Disable Windows Update
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Stop-Service -Name UsoSvc -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
Set-Service -Name UsoSvc -StartupType Disabled -ErrorAction SilentlyContinue

# Registry to skip OOBE
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" -Name "SkipMachineOOBE" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" -Name "SkipUserOOBE" -Value 1 -Type DWord -Force

# Disable Windows Update
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord -Force

# Install Cloudbase-Init
Write-Host "Installing Cloudbase-Init..." -ForegroundColor Yellow
$url = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$output = "$env:TEMP\CloudbaseInitSetup.msi"
Invoke-WebRequest -Uri $url -OutFile $output -UseBasicParsing -TimeoutSec 300
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$output`" /quiet /norestart LOGGINGLEVEL=3 Username=`"Administrator`" RunCloudbaseInitServiceAsLocalSystem=1" -Wait -NoNewWindow
Start-Sleep -Seconds 5

# Configure Administrator
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

# Run Sysprep
Write-Host "Running Sysprep..." -ForegroundColor Cyan
& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet

Write-Host "SetupComplete finished." -ForegroundColor Green
Stop-Transcript
EOF

# ----------------------------------------------------------------------------
# Create autounattend.xml with FULL OOBE bypass
# ----------------------------------------------------------------------------
ANSWERFILE="$WORK_DIR/autounattend.xml"
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
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64">
            <ComputerName>WIN10-TPL</ComputerName>
            <TimeZone>UTC</TimeZone>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v SkipMachineOOBE /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v SkipUserOOBE /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipFirstLogonTasks>true</SkipFirstLogonTasks>
                <ProtectYourPC>3</ProtectYourPC>
                <NetworkLocation>Work</NetworkLocation>
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
                <LogonCount>5</LogonCount>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c mkdir C:\Windows\Setup\Scripts</CommandLine>
                    <Order>1</Order>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>copy D:\SetupComplete.ps1 C:\Windows\Setup\Scripts\SetupComplete.ps1</CommandLine>
                    <Order>2</Order>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell.exe -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\SetupComplete.ps1</CommandLine>
                    <Order>3</Order>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
EOF

# ----------------------------------------------------------------------------
# Create answer media
# ----------------------------------------------------------------------------
echo_color "Creating answer media..." "$CYAN"

ISO_DIR="$WORK_DIR/iso_source"
mkdir -p "$ISO_DIR"
cp "$ANSWERFILE" "$ISO_DIR/autounattend.xml"
cp "$SETUP_SCRIPT" "$ISO_DIR/SetupComplete.ps1"

# Convert ISO_DIR to Windows path for QEMU
if command -v cygpath &> /dev/null; then
    ISO_DIR_WIN=$(cygpath -w "$ISO_DIR")
else
    ISO_DIR_WIN=$(echo "$ISO_DIR" | sed 's/^\/tmp\//C:\\Temp\\/' | sed 's/\//\\/g')
fi
echo_color "Answer media path: $ISO_DIR_WIN" "$GRAY"

# ----------------------------------------------------------------------------
# Create QCOW2 disk
# ----------------------------------------------------------------------------
if [ -f "$OUTPUT_QCOW2" ]; then
    echo_color "Removing existing disk..." "$YELLOW"
    rm -f "$OUTPUT_QCOW2"
fi

echo_color "Creating QCOW2 disk: $OUTPUT_QCOW2 ($DISK_SIZE)" "$CYAN"
qemu-img create -f qcow2 "$OUTPUT_QCOW2" "$DISK_SIZE"

# ----------------------------------------------------------------------------
# Launch QEMU - use Windows paths directly
# ----------------------------------------------------------------------------
echo ""
echo_color "============================================================" "$CYAN"
echo_color "Starting QEMU installation..." "$CYAN"
echo_color "OOBE and Windows Update have been bypassed" "$GREEN"
echo_color "============================================================" "$CYAN"
echo ""

# Use Windows paths for all file arguments
"$QEMU_PATH" \
    -accel tcg \
    -cpu qemu64 \
    -smp "$CPU_CORES" \
    -m "${RAM_MB}M" \
    -drive "file=$OUTPUT_QCOW2_WIN,format=qcow2,if=ide,index=0" \
    -drive "file=$ISO_PATH_WIN,if=ide,index=1,media=cdrom" \
    -drive "file=fat:ro:$ISO_DIR_WIN,if=ide,index=2,media=cdrom" \
    -vga qxl \
    -display gtk \
    -machine type=pc \
    -rtc base=localtime \
    -boot order=d

# ----------------------------------------------------------------------------
# Check results
# ----------------------------------------------------------------------------
if [ -f "$OUTPUT_QCOW2" ]; then
    SIZE=$(stat -c%s "$OUTPUT_QCOW2" 2>/dev/null || echo 0)
    SIZE_GB=$((SIZE / 1024 / 1024 / 1024))
    echo_color "Disk image size: ${SIZE_GB} GB" "$CYAN"
    
    if [ $SIZE_GB -gt 5 ]; then
        echo_color "Compressing final template..." "$CYAN"
        TEMPLATE="$SCRIPT_DIR/windows10-template.qcow2"
        qemu-img convert -c -O qcow2 "$OUTPUT_QCOW2" "$TEMPLATE"
        
        echo ""
        echo_color "============================================================" "$GREEN"
        echo_color "SUCCESS!" "$GREEN"
        echo_color "============================================================" "$GREEN"
        echo_color "Final image: $TEMPLATE" "$WHITE"
        echo_color "Administrator password: $ADMIN_PASSWORD" "$WHITE"
    else
        echo_color "WARNING: Image size too small - installation failed." "$RED"
    fi
fi

# Cleanup
rm -rf "$WORK_DIR"
echo_color "Script completed!" "$GREEN"