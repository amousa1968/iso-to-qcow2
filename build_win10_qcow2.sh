#!/bin/bash
# build_win10_qcow2.sh - Bypasses Microsoft account requirement

set -euo pipefail

# ----- Configuration -----
ISO_PATH="windows10_21h2.iso"
OUTPUT_QCOW2="windows10-template.qcow2"
DISK_SIZE="120G"
RAM_MB="8192"
CPU_CORES="6"
ADMIN_PASSWORD="Password123!"

# ----- Find QEMU installation -----
QEMU_PATH=""
if command -v qemu-system-x86_64 &> /dev/null; then
    QEMU_PATH="qemu-system-x86_64"
elif [ -f "/c/Program Files/qemu/qemu-system-x86_64.exe" ]; then
    QEMU_PATH="/c/Program Files/qemu/qemu-system-x86_64.exe"
elif [ -f "/c/Program Files (x86)/qemu/qemu-system-x86_64.exe" ]; then
    QEMU_PATH="/c/Program Files (x86)/qemu/qemu-system-x86_64.exe"
else
    echo "ERROR: QEMU not found. Please install QEMU first."
    exit 1
fi

echo "Using QEMU: $QEMU_PATH"

# ----- Create working directory -----
WORK_DIR=$(mktemp -d)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSWERFILE="$SCRIPT_DIR/autounattend.xml"
POWERSHELL_SCRIPT="$SCRIPT_DIR/install-cloudbase.ps1"
VIRTIO_WIN_ISO="virtio-win.iso"

# Check for virtio-win.iso
if [ ! -f "$VIRTIO_WIN_ISO" ]; then
    echo "NOTE: virtio-win.iso not found. This is optional - Windows will use IDE drivers."
    VIRTIO_WIN_ISO=""
fi

# ----- Sanity checks -----
if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: ISO not found at $ISO_PATH"
    echo "Current directory: $(pwd)"
    ls -la *.iso 2>/dev/null || echo "No ISO files found"
    exit 1
fi

# ----- 1. Create the QCOW2 disk -----
echo "Creating QCOW2 disk: $OUTPUT_QCOW2 ($DISK_SIZE)"
qemu-img create -f qcow2 "$OUTPUT_QCOW2" "$DISK_SIZE"

# ----- 2. Generate the PowerShell script -----
cat > "$POWERSHELL_SCRIPT" << 'EOF'
# install-cloudbase.ps1 - First boot script

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Starting Windows Image Preparation" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ----- Disable Windows Update and related services -----
Write-Host "Disabling Windows Update services..." -ForegroundColor Yellow

$servicesToDisable = @(
    "wuauserv",
    "UsoSvc",
    "WaaSMedicSvc",
    "bits",
    "DoSvc",
    "TrustedInstaller"
)

foreach ($service in $servicesToDisable) {
    Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
    Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "  Disabled: $service"
}

# Disable automatic updates via registry
Write-Host "Disabling automatic updates via registry..." -ForegroundColor Yellow
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Value 1 -Type DWord -Force

# Stop Windows Update background processes
Get-Process -Name "TrustedInstaller" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "wuauclt" -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host "Windows Update has been disabled." -ForegroundColor Green

# ----- Clean temporary files -----
Write-Host "Cleaning temporary files..." -ForegroundColor Yellow
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue

# ----- Install Cloudbase-Init -----
Write-Host "Downloading Cloudbase-Init..." -ForegroundColor Yellow
$url = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$output = "$env:TEMP\CloudbaseInitSetup.msi"
Invoke-WebRequest -Uri $url -OutFile $output -UseBasicParsing

Write-Host "Installing Cloudbase-Init..." -ForegroundColor Yellow
$process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$output`" /quiet /norestart LOGGINGLEVEL=3 Username=`"Administrator`" RunCloudbaseInitServiceAsLocalSystem=1" -Wait -PassThru

Start-Sleep -Seconds 5

# ----- Configure Administrator account -----
Write-Host "Configuring Administrator account..." -ForegroundColor Yellow
net user Administrator "Password123!" /logonpasswordchg:no 2>$null
wmic UserAccount where "Name='Administrator'" set PasswordExpires=False 2>$null

# Enable Administrator account (in case it's disabled)
net user Administrator /active:yes 2>$null

# ----- Configure WinRM -----
Write-Host "Configuring WinRM..." -ForegroundColor Yellow
winrm quickconfig -q -force 2>$null
winrm set winrm/config/service/auth '@{Basic="true"}' 2>$null
winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>$null

# ----- Configure cloudbase-init -----
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
}

# Restart service
Restart-Service CloudbaseInit -ErrorAction SilentlyContinue

# ----- Final cleanup before Sysprep -----
Write-Host "Performing final cleanup before Sysprep..." -ForegroundColor Yellow

# Clear event logs
wevtutil el | ForEach-Object { wevtutil cl $_ 2>$null }

# Clear Windows Update logs
Remove-Item -Path "C:\Windows\Logs\WindowsUpdate\*" -Force -ErrorAction SilentlyContinue

# Clear CBS logs
Remove-Item -Path "C:\Windows\Logs\CBS\*" -Force -ErrorAction SilentlyContinue

# Disable hibernation
powercfg -h off

# Reduce page file
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "PagingFiles" -Value "C:\pagefile.sys 256 256" -Force

# Remove pending reboot flags
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name "RebootRequired" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue

# Wait for any pending operations to complete
Write-Host "Waiting for pending operations to complete..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# ----- Run Sysprep -----
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
        
        $sysprepLog = "$env:SystemRoot\System32\Sysprep\Panther\setupact.log"
        if (Test-Path $sysprepLog) {
            Write-Host "Last 20 lines of Sysprep log:" -ForegroundColor Yellow
            Get-Content $sysprepLog -Tail 20
        }
    }
} catch {
    Write-Host "Sysprep execution failed: $_" -ForegroundColor Red
}

Write-Host "VM will now shut down." -ForegroundColor Green
EOF

# ----- 3. Generate autounattend.xml with Microsoft account bypass -----
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
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>1</Value>
                        </MetaData>
                    </InstallFrom>
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
                <HideLocalAccountScreen>false</HideLocalAccountScreen>
                <ProtectYourPC>1</ProtectYourPC>
                <NetworkLocation>Work</NetworkLocation>
            </OOBE>
            <AutoLogon>
                <Enabled>true</Enabled>
                <Username>Administrator</Username>
                <Password>
                    <Value>Password123!</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>2</LogonCount>
            </AutoLogon>
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
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>cmd.exe /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f</CommandLine>
                    <Order>1</Order>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell.exe -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\install-cloudbase.ps1"</CommandLine>
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

# Convert to Windows line endings
sed -i 's/$/\r/' "$ANSWERFILE" 2>/dev/null || echo ""

# ----- 4. Create answer ISO -----
echo "Creating answer ISO..."
ANSWER_ISO="$WORK_DIR/answer.iso"
powershell.exe -Command "
    \$isoPath = '$ANSWER_ISO'
    \$sourceFolder = '$SCRIPT_DIR'
    \$iso = New-Object -ComObject IMAPI2FS.MsftIsoImage
    \$iso.VolumeName = 'AUTORUN'
    \$root = \$iso.Root
    \$root.AddFile('\$sourceFolder\autounattend.xml', '\$sourceFolder\autounattend.xml')
    \$scriptsDir = \$root.AddDirectory('Windows')
    \$scriptsDir = \$scriptsDir.AddDirectory('Setup')
    \$scriptsDir = \$scriptsDir.AddDirectory('Scripts')
    \$scriptsDir.AddFile('\$sourceFolder\install-cloudbase.ps1', '\$sourceFolder\install-cloudbase.ps1')
    \$stream = [System.IO.File]::OpenWrite(\$isoPath)
    \$iso.WriteToStream(\$stream)
    \$stream.Close()
    Write-Host 'ISO created successfully'
" 2>/dev/null || {
    echo "PowerShell ISO creation failed"
    exit 1
}

# ----- 5. Launch QEMU -----
echo ""
echo "========================================="
echo "Starting QEMU installation..."
echo "This will take 20-40 minutes"
echo "Microsoft account login has been bypassed"
echo "Local Administrator account will be used"
echo "========================================="
echo ""

# Build QEMU command
QEMU_CMD="\"$QEMU_PATH\" -cpu qemu64 -smp $CPU_CORES -m $RAM_MB \
    -drive file=\"$OUTPUT_QCOW2\",format=qcow2,if=ide,index=0 \
    -drive file=\"$ISO_PATH\",format=raw,if=ide,index=1,media=cdrom"

# Add answer ISO
if [ -f "$ANSWER_ISO" ]; then
    QEMU_CMD="$QEMU_CMD -drive file=\"$ANSWER_ISO\",format=raw,if=ide,index=2,media=cdrom"
fi

# Add virtio-win ISO if available
if [ -n "$VIRTIO_WIN_ISO" ] && [ -f "$VIRTIO_WIN_ISO" ]; then
    QEMU_CMD="$QEMU_CMD -drive file=\"$VIRTIO_WIN_ISO\",format=raw,if=ide,index=3,media=cdrom"
fi

# Windows-optimized flags
QEMU_CMD="$QEMU_CMD -vga qxl -display gtk -machine type=pc -usb -device usb-tablet -rtc base=localtime"

echo "Running: $QEMU_CMD"
echo ""

eval "$QEMU_CMD"

# ----- 6. Wait for completion -----
echo "Waiting for Windows installation and Sysprep to finish..."
while pgrep -f "qemu-system-x86_64" > /dev/null; do
    sleep 10
done

# ----- 7. Compress the final image -----
echo "Compressing final template..."
TEMPLATE="${OUTPUT_QCOW2%.qcow2}-template.qcow2"
qemu-img convert -c -O qcow2 "$OUTPUT_QCOW2" "$TEMPLATE"

# ----- 8. Cleanup -----
rm -rf "$WORK_DIR"
rm -f "$ANSWERFILE" "$POWERSHELL_SCRIPT"

echo ""
echo "============================================="
echo "SUCCESS!"
echo "Final image: $TEMPLATE"
echo "Administrator password: $ADMIN_PASSWORD"
echo ""
echo "To test the image:"
echo "\"$QEMU_PATH\" -m 4096 -drive file=$TEMPLATE,format=qcow2,if=ide -vga qxl -display gtk"
echo "============================================="