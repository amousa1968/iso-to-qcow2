# build_win10_qcow2.ps1 - Working with multiple acceleration options
# Save as: build_win10_qcow2.ps1
# Run with: powershell -ExecutionPolicy Bypass -File "build_win10_qcow2.ps1"

param(
    [string]$ISOPath = "windows10_21h2.iso",
    [string]$OutputQCOW2 = "windows10-template.qcow2",
    [string]$DiskSize = "120G",
    [int]$RAM_MB = 4096,
    [int]$CPUCores = 2,
    [string]$AdminPassword = "Password123!"
)

# Self-elevation
$selfScript = $MyInvocation.MyCommand.Path
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    $bypassCmd = "-ExecutionPolicy Bypass -File `"$selfScript`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $bypassCmd
    exit
}

$ErrorActionPreference = "Continue"

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# Get script directory
$SCRIPT_DIR = $PSScriptRoot
if (-not $SCRIPT_DIR) {
    $SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
Set-Location $SCRIPT_DIR
Write-ColorOutput "Working directory: $SCRIPT_DIR" "Cyan"

# Find Windows ISO
$ISOPath = Resolve-Path $ISOPath -ErrorAction SilentlyContinue
if (-not $ISOPath) {
    $isoCandidates = @("windows10_21h2.iso", "win10.iso", "windows10.iso", "Win10_22H2.iso")
    foreach ($candidate in $isoCandidates) {
        $testPath = Join-Path $SCRIPT_DIR $candidate
        if (Test-Path $testPath) {
            $ISOPath = $testPath
            break
        }
    }
}
if (-not $ISOPath) {
    Write-ColorOutput "ERROR: Windows ISO not found!" "Red"
    Get-ChildItem *.iso -ErrorAction SilentlyContinue | ForEach-Object { Write-ColorOutput "  Found: $($_.Name)" "Yellow" }
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
$ISOPath = $ISOPath.ToString()
Write-ColorOutput "Windows ISO: $ISOPath" "Green"

$OutputQCOW2 = Join-Path $SCRIPT_DIR $OutputQCOW2
Write-ColorOutput "Output disk: $OutputQCOW2" "Green"

# Find QEMU
$QEMUPath = "C:\Program Files\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $QEMUPath)) {
    Write-ColorOutput "ERROR: QEMU not found at $QEMUPath" "Red"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
Write-ColorOutput "QEMU: $QEMUPath" "Green"

# Detect available acceleration
$accel = "tcg"
$cpuType = "qemu64"
$accelName = "TCG (Software Emulation)"
$expectedTime = "2-3 hours"

# Try to detect WHPX (Windows Hypervisor Platform)
$whpxAvailable = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue
$whpxState = $whpxAvailable.State -eq "Enabled"

# Try to detect HAXM (Intel HAXM)
$haxmInstalled = Test-Path "C:\Windows\System32\drivers\haXM.sln"

# Try to detect if we're on a system that supports HVF (macOS only) - not on Windows
# For Windows, WHPX is the main option

Write-ColorOutput "Detecting available acceleration..." "Cyan"

# For Windows 11, WHPX often has issues with QEMU. Let's use TCG (works always)
Write-ColorOutput "Using TCG software emulation (compatible, but slower)" "Yellow"
Write-ColorOutput "Expected time: 2-3 hours" "Yellow"
Write-ColorOutput ""
Write-ColorOutput "For faster installation (30-45 minutes), consider:" "Cyan"
Write-ColorOutput "  1. Use WSL2 with KVM (recommended)" "Green"
Write-ColorOutput "  2. Install Intel HAXM for Windows" "Green"
Write-ColorOutput "  3. Use a Linux VM with KVM" "Green"
Write-ColorOutput ""

# Create working directory
$WORK_DIR = Join-Path $env:TEMP "qemu_build_$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $WORK_DIR -Force | Out-Null
Write-ColorOutput "Temp dir: $WORK_DIR" "Gray"

# Download virtio-win.iso (optional)
$VIRTIO_WIN_ISO = Join-Path $SCRIPT_DIR "virtio-win.iso"
if (-not (Test-Path $VIRTIO_WIN_ISO)) {
    Write-ColorOutput "Downloading virtio-win.iso for better performance..." "Yellow"
    try {
        Invoke-WebRequest -Uri "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" -OutFile $VIRTIO_WIN_ISO -UseBasicParsing -TimeoutSec 300
        Write-ColorOutput "virtio-win.iso downloaded" "Green"
    } catch {
        Write-ColorOutput "WARNING: Could not download virtio-win.iso, using IDE instead" "Yellow"
        $VIRTIO_WIN_ISO = $null
    }
}

# Create SetupComplete.ps1
$SETUPSCRIPT = Join-Path $WORK_DIR "SetupComplete.ps1"
@'
# SetupComplete.ps1
Start-Transcript -Path "C:\Windows\Temp\SetupComplete.log"

Write-Host "SetupComplete script running..." -ForegroundColor Cyan

Start-Sleep -Seconds 15

# Disable Windows Update
$services = @("wuauserv", "UsoSvc", "WaaSMedicSvc", "bits", "DoSvc")
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

Stop-Transcript
'@ | Out-File -FilePath $SETUPSCRIPT -Encoding ASCII

# Create autounattend.xml
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
'@ | Out-File -FilePath $ANSWERFILE -Encoding ASCII

# Create answer folder
$ISO_DIR = Join-Path $WORK_DIR "iso_source"
New-Item -ItemType Directory -Path $ISO_DIR -Force | Out-Null
Copy-Item $ANSWERFILE "$ISO_DIR\autounattend.xml"
Copy-Item $SETUPSCRIPT "$ISO_DIR\SetupComplete.ps1"

# Remove old disk if exists
if (Test-Path $OutputQCOW2) {
    Write-ColorOutput "Removing existing disk..." "Yellow"
    Remove-Item $OutputQCOW2 -Force
}

# Create QCOW2 disk
Write-ColorOutput "Creating QCOW2 disk: $OutputQCOW2 ($DiskSize)" "Cyan"
& qemu-img create -f qcow2 "$OutputQCOW2" "$DiskSize"

# Launch QEMU
Write-ColorOutput "" "White"
Write-ColorOutput "=========================================" "Cyan"
Write-ColorOutput "Starting QEMU installation..." "Cyan"
Write-ColorOutput "Mode: $accelName" "Yellow"
Write-ColorOutput "Expected time: $expectedTime" "Yellow"
Write-ColorOutput "=========================================" "Cyan"
Write-ColorOutput "" "White"

# Build argument list
$qemuArgs = @(
    "-accel", $accel
    "-cpu", $cpuType
    "-smp", $CPUCores.ToString()
    "-m", "${RAM_MB}M"
)

# Disk drive - always use IDE since VirtIO can be problematic
$qemuArgs += "-drive", "file=`"$OutputQCOW2`",format=qcow2,if=ide,index=0"
Write-ColorOutput "Using IDE disk driver (most compatible)" "Yellow"

# Windows ISO drive
$qemuArgs += "-drive", "file=`"$ISOPath`",if=ide,index=1,media=cdrom"

# Answer folder drive
$qemuArgs += "-drive", "file=fat:ro:`"$ISO_DIR`",if=ide,index=2,media=cdrom"

$qemuArgs += @(
    "-vga", "qxl"
    "-display", "gtk"
    "-machine", "type=pc"
    "-rtc", "base=localtime"
    "-boot", "order=d"
)

Write-ColorOutput "Starting QEMU..." "Green"
Write-ColorOutput "Command: $QEMUPath $($qemuArgs -join ' ')" "Gray"
Write-ColorOutput ""

try {
    $process = Start-Process -FilePath $QEMUPath -ArgumentList $qemuArgs -PassThru -NoNewWindow
    Write-ColorOutput "QEMU PID: $($process.Id)" "Gray"
    Write-ColorOutput "Waiting for installation to complete..." "Yellow"
    Write-ColorOutput "The QEMU window should open. DO NOT CLOSE IT." "Cyan"
    Write-ColorOutput ""
    Write-ColorOutput "This will take 2-3 hours. Please be patient." "Yellow"
    Write-ColorOutput ""
    
    $process.WaitForExit()
    Write-ColorOutput "QEMU exited with code: $($process.ExitCode)" "Cyan"
} catch {
    Write-ColorOutput "Failed to start QEMU: $_" "Red"
}

# Check results
if (Test-Path $OutputQCOW2) {
    $size = (Get-Item $OutputQCOW2).Length
    Write-ColorOutput "Disk image size: $([math]::Round($size/1GB, 2)) GB" "Cyan"
    
    if ($size -gt 5GB) {
        Write-ColorOutput "Compressing final template..." "Cyan"
        $TEMPLATE = Join-Path $SCRIPT_DIR "windows10-template.qcow2"
        & qemu-img convert -c -O qcow2 "$OutputQCOW2" "$TEMPLATE"
        
        Write-ColorOutput "" "Green"
        Write-ColorOutput "=============================================" "Green"
        Write-ColorOutput "SUCCESS!" "Green"
        Write-ColorOutput "=============================================" "Green"
        Write-ColorOutput "Final image: $TEMPLATE" "White"
        Write-ColorOutput "Administrator password: $AdminPassword" "White"
        Write-ColorOutput ""
        Write-ColorOutput "To test the image:" "Yellow"
        Write-ColorOutput "$QEMUPath -accel tcg -cpu qemu64 -m 4096 -drive file=`"$TEMPLATE`",format=qcow2,if=ide -vga qxl -display gtk" "White"
        Write-ColorOutput "=============================================" "Green"
    } else {
        Write-ColorOutput "WARNING: Image size is only $([math]::Round($size/1MB, 2)) MB - installation failed" "Red"
        Write-ColorOutput "Try checking if the Windows ISO is bootable" "Yellow"
    }
}

# Cleanup
Write-ColorOutput "Cleaning up temporary files..." "Gray"
Remove-Item -Path $WORK_DIR -Recurse -Force -ErrorAction SilentlyContinue

Write-ColorOutput "Script completed!" "Green"