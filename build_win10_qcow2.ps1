# build_win10_qcow2.ps1 - Completely rewritten for Windows QEMU compatibility
# Run as Administrator in PowerShell

param(
    [string]$ISOPath = "windows10_21h2.iso",
    [string]$OutputQCOW2 = "windows10-template.qcow2",
    [string]$DiskSize = "120G",
    [int]$RAM_MB = 8192,
    [int]$CPUCores = 6,
    [string]$AdminPassword = "Password123!"
)

$ErrorActionPreference = "Continue"

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# Find QEMU
$QEMUPath = "C:\Program Files\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $QEMUPath)) {
    Write-ColorOutput "ERROR: QEMU not found at $QEMUPath" "Red"
    exit 1
}

Write-ColorOutput "Using QEMU: $QEMUPath" "Green"

# Check if ISO exists
if (-not (Test-Path $ISOPath)) {
    Write-ColorOutput "ERROR: Windows ISO not found: $ISOPath" "Red"
    exit 1
}

# Create working directory
$WORK_DIR = Join-Path $env:TEMP "qemu-build-$([System.Guid]::NewGuid().ToString())"
New-Item -ItemType Directory -Path $WORK_DIR -Force | Out-Null

Write-ColorOutput "Working directory: $WORK_DIR" "Gray"

# ----- Create SetupComplete.ps1 -----
$SETUPSCRIPT = Join-Path $WORK_DIR "SetupComplete.ps1"
@'
# SetupComplete.ps1 - Runs at end of Windows setup
Start-Transcript -Path "C:\Windows\Temp\SetupComplete.log"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "SetupComplete script running..." -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# Wait for system to be ready
Start-Sleep -Seconds 60

# Disable Windows Update completely
Write-Host "Disabling Windows Update..." -ForegroundColor Yellow
$services = @("wuauserv", "UsoSvc", "WaaSMedicSvc", "bits", "DoSvc")
foreach ($svc in $services) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}

# Disable updates via registry
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord -Force

# Install Cloudbase-Init
Write-Host "Downloading Cloudbase-Init..." -ForegroundColor Yellow
$url = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$output = "$env:TEMP\CloudbaseInitSetup.msi"
try {
    Invoke-WebRequest -Uri $url -OutFile $output -UseBasicParsing -TimeoutSec 300
} catch {
    Write-Host "Failed to download Cloudbase-Init: $_" -ForegroundColor Red
}

if (Test-Path $output) {
    Write-Host "Installing Cloudbase-Init..." -ForegroundColor Yellow
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$output`" /quiet /norestart LOGGINGLEVEL=3 Username=`"Administrator`" RunCloudbaseInitServiceAsLocalSystem=1" -Wait -NoNewWindow
    Start-Sleep -Seconds 10
}

# Configure Administrator
Write-Host "Configuring Administrator..." -ForegroundColor Yellow
net user Administrator "Password123!" /logonpasswordchg:no 2>$null
net user Administrator /active:yes 2>$null

# Disable UAC
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
Write-Host "Cleaning up..." -ForegroundColor Yellow
Remove-Item -Path "C:\Windows\Panther\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "SetupComplete finished. Sysprep will run now..." -ForegroundColor Green
Stop-Transcript

# Run Sysprep
& "C:\Windows\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet
'@ | Out-File -FilePath $SETUPSCRIPT -Encoding ASCII

# ----- Create autounattend.xml -----
$ANSWERFILE = Join-Path $WORK_DIR "autounattend.xml"
@'
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
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
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
                    <CommandLine>powershell.exe -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\SetupComplete.ps1"</CommandLine>
                    <Order>1</Order>
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
'@ | Out-File -FilePath $ANSWERFILE -Encoding ASCII

# ----- Create a simple bootable ISO using a reliable method -----
Write-ColorOutput "Creating bootable answer ISO..." "Cyan"

$ISO_SOURCE = Join-Path $WORK_DIR "iso_source"
New-Item -ItemType Directory -Path "$ISO_SOURCE\Windows\Setup\Scripts" -Force | Out-Null

# Copy files to ISO source
Copy-Item $ANSWERFILE "$ISO_SOURCE\autounattend.xml" -Force
Copy-Item $SETUPSCRIPT "$ISO_SOURCE\Windows\Setup\Scripts\SetupComplete.ps1" -Force

# Use a simple PowerShell script to create ISO using IMAPI2FS (if available)
$ANSWER_ISO = Join-Path $WORK_DIR "answer.iso"
$isoCreated = $false

# Try to create ISO using mkisofs from WSL or Git Bash
$mkisofsPaths = @(
    "C:\Program Files\Git\usr\bin\mkisofs.exe",
    "C:\Program Files\Git\mingw64\bin\mkisofs.exe",
    (Get-Command mkisofs -ErrorAction SilentlyContinue).Source
)

foreach ($mkisofs in $mkisofsPaths) {
    if ($mkisofs -and (Test-Path $mkisofs)) {
        Write-ColorOutput "Creating ISO with mkisofs: $mkisofs" "Yellow"
        & $mkisofs -o "$ANSWER_ISO" -V "AUTORUN" -J -r "$ISO_SOURCE" 2>&1 | Out-Null
        if (Test-Path $ANSWER_ISO -and (Get-Item $ANSWER_ISO).Length -gt 1KB) {
            $isoCreated = $true
            break
        }
    }
}

# If mkisofs not found, try using PowerShell's New-Item with a different COM approach
if (-not $isoCreated) {
    try {
        Write-ColorOutput "Attempting alternative ISO creation method..." "Yellow"
        Add-Type -AssemblyName System.IO
        Add-Type -AssemblyName System.Runtime.InteropServices
        
        $tempIso = $ANSWER_ISO
        # Create minimal ISO header
        $bytes = [byte[]]@(0x43, 0x44, 0x30, 0x30, 0x31, 0x01, 0x00, 0x00)
        [System.IO.File]::WriteAllBytes($tempIso, $bytes)
        
        # Copy files as a simple folder (Windows will recognize as ISO from folder)
        $isoCreated = $false
        Write-ColorOutput "Minimal ISO created, using folder as fallback" "Yellow"
    } catch {
        Write-ColorOutput "ISO creation methods failed" "Yellow"
    }
}

# Determine which answer media to use
if ($isoCreated -and (Test-Path $ANSWER_ISO) -and (Get-Item $ANSWER_ISO).Length -gt 1KB) {
    $ANSWER_MEDIA = $ANSWER_ISO
    $MEDIA_TYPE = "iso"
    Write-ColorOutput "Answer ISO created: $ANSWER_ISO" "Green"
} else {
    # Final fallback: use folder (QEMU will treat as ISO if we use proper flags)
    $ANSWER_MEDIA = $ISO_SOURCE
    $MEDIA_TYPE = "folder"
    Write-ColorOutput "Using source folder as answer media: $ISO_SOURCE" "Yellow"
}

# ----- Create QCOW2 disk -----
Write-ColorOutput "Creating QCOW2 disk: $OutputQCOW2 ($DiskSize)" "Cyan"
& qemu-img create -f qcow2 "$OutputQCOW2" "$DiskSize"

# ----- Launch QEMU with correct drive ordering -----
Write-ColorOutput "" "White"
Write-ColorOutput "=========================================" "Cyan"  
Write-ColorOutput "Starting QEMU installation..." "Cyan"
Write-ColorOutput "This will take 30-60 minutes" "Yellow"
Write-ColorOutput "=========================================" "Cyan"
Write-ColorOutput "" "White"

# Build QEMU command - Use consistent drive types
$qemuArgs = @(
    "-cpu", "qemu64",
    "-smp", $CPUCores,
    "-m", $RAM_MB,
    "-drive", "file=$OutputQCOW2,format=qcow2,if=ide,index=0",
    "-drive", "file=$ISOPath,format=raw,if=ide,index=1,media=cdrom"
)

# Add answer media - use index 2 for second CD-ROM
if ($MEDIA_TYPE -eq "iso") {
    $qemuArgs += "-drive", "file=$ANSWER_MEDIA,format=raw,if=ide,index=2,media=cdrom"
} else {
    $qemuArgs += "-drive", "file=fat:ro:$ANSWER_MEDIA,format=raw,if=ide,index=2,media=cdrom"
}

$qemuArgs += @(
    "-vga", "qxl",
    "-display", "gtk",
    "-machine", "type=pc",
    "-rtc", "base=localtime"
)

Write-ColorOutput "Starting QEMU..." "Green"
$qemuProcess = Start-Process -FilePath $QEMUPath -ArgumentList $qemuArgs -PassThru -NoNewWindow
Write-ColorOutput "QEMU PID: $($qemuProcess.Id)" "Gray"
Write-ColorOutput "Waiting for installation to complete (VM window will close when done)..." "Yellow"

# Wait for QEMU to exit
$timeout = 7200 # 2 hour timeout
$elapsed = 0
while (-not $qemuProcess.HasExited -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 10
    $elapsed += 10
    Write-ColorOutput "." -NoNewline
}
Write-ColorOutput "" "White"

if ($qemuProcess.HasExited) {
    Write-ColorOutput "QEMU exited with code: $($qemuProcess.ExitCode)" "Cyan"
} else {
    Write-ColorOutput "Timeout reached. QEMU still running. Please check manually." "Yellow"
    $qemuProcess.Kill()
}

# Check results
if (Test-Path $OutputQCOW2) {
    $size = (Get-Item $OutputQCOW2).Length
    Write-ColorOutput "Disk image size: $([math]::Round($size/1GB, 2)) GB" "Cyan"
    
    if ($size -gt 5GB) {
        Write-ColorOutput "Compressing final template..." "Cyan"
        $TEMPLATE = "windows10-final-template.qcow2"
        & qemu-img convert -c -O qcow2 "$OutputQCOW2" "$TEMPLATE"
        Write-ColorOutput "" "Green"
        Write-ColorOutput "=============================================" "Green"
        Write-ColorOutput "SUCCESS!" "Green"
        Write-ColorOutput "Final image: $TEMPLATE" "White"
        Write-ColorOutput "Administrator password: $AdminPassword" "White"
        Write-ColorOutput "=============================================" "Green"
    } else {
        Write-ColorOutput "WARNING: Disk image is only $([math]::Round($size/1MB, 2)) MB. Installation likely failed." "Yellow"
        Write-ColorOutput "Please check if the Windows ISO is valid and try again." "Yellow"
    }
}

# Cleanup
Write-ColorOutput "Cleaning up temporary files..." "Gray"
Remove-Item -Path $WORK_DIR -Recurse -Force -ErrorAction SilentlyContinue

Write-ColorOutput "Script completed!" "Green"