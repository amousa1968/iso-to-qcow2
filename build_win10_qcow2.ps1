# build_win10_qcow2.ps1 - Final version with working local account bypass
# Run with: powershell -ExecutionPolicy Bypass -File "build_win10_qcow2.ps1"

param(
    [string]$ISOPath = "windows10_21h2.iso",
    [string]$OutputQCOW2 = "windows10-template.qcow2",
    [string]$DiskSize = "120G",
    [int]$RAM_MB = 4096,
    [int]$CPUCores = 2,
    [string]$AdminPassword = "Password123!"
)

$ErrorActionPreference = "Stop"

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# Self-elevation
$selfScript = $MyInvocation.MyCommand.Path
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isAdmin) {
    Write-ColorOutput "Requesting administrator privileges..." "Yellow"
    $bypassCmd = "-ExecutionPolicy Bypass -File `"$selfScript`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $bypassCmd
    exit
}

# Function to get short path (8.3 format)
function Get-ShortPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if (-not (Test-Path $Path)) { return $Path }
    $shortPath = cmd /c "for %I in (`"$Path`") do @echo %~sI" 2>$null
    if ($shortPath) {
        return $shortPath.Trim()
    }
    return $Path
}

# Get script directory
$SCRIPT_DIR = $PSScriptRoot
if (-not $SCRIPT_DIR) {
    $SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$SCRIPT_DIR_SHORT = Get-ShortPath $SCRIPT_DIR
Set-Location $SCRIPT_DIR
Write-ColorOutput "Working directory: $SCRIPT_DIR_SHORT" "Cyan"

# Find QEMU
$QEMUPath = "C:\PROGRA~1\qemu\qemu-system-x86_64.exe"
if (-not (Test-Path $QEMUPath)) {
    $QEMUPath = "C:\Program Files\qemu\qemu-system-x86_64.exe"
    $QEMUPath = Get-ShortPath $QEMUPath
}
if (-not (Test-Path $QEMUPath)) {
    Write-ColorOutput "ERROR: QEMU not found!" "Red"
    exit 1
}
Write-ColorOutput "Using QEMU: $QEMUPath" "Green"

# Find Windows ISO
$ISOPathObj = Resolve-Path $ISOPath -ErrorAction SilentlyContinue
if (-not $ISOPathObj) {
    $isoCandidates = @("windows10_21h2.iso", "win10.iso", "windows10.iso", "Win10_22H2.iso")
    foreach ($candidate in $isoCandidates) {
        $testPath = Join-Path $SCRIPT_DIR $candidate
        if (Test-Path $testPath) {
            $ISOPathObj = $testPath
            break
        }
    }
}
if (-not $ISOPathObj) {
    Write-ColorOutput "ERROR: Windows ISO not found!" "Red"
    exit 1
}
$ISOPathShort = Get-ShortPath $ISOPathObj.ToString()
Write-ColorOutput "Windows ISO: $ISOPathShort" "Green"

$OutputQCOW2 = Join-Path $SCRIPT_DIR $OutputQCOW2
$OutputQCOW2Short = Get-ShortPath $OutputQCOW2

# ----------------------------------------------------------------------------
# Create working directory
# ----------------------------------------------------------------------------
$WORK_DIR = Join-Path $env:TEMP "qemu_build_$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $WORK_DIR -Force | Out-Null
Write-ColorOutput "Working directory: $WORK_DIR" "Green"

# ----------------------------------------------------------------------------
# Create SetupComplete.ps1
# ----------------------------------------------------------------------------
$SETUPSCRIPT = Join-Path $WORK_DIR "SetupComplete.ps1"
$setupContent = @'
# SetupComplete.ps1 - Runs after OOBE
Start-Transcript -Path "C:\Windows\Temp\SetupComplete.log"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "SetupComplete script running..." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Start-Sleep -Seconds 30

# Disable Windows Update permanently
Write-Host "Disabling Windows Update..." -ForegroundColor Yellow
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Stop-Service -Name UsoSvc -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
Set-Service -Name UsoSvc -StartupType Disabled -ErrorAction SilentlyContinue

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
'@
[System.IO.File]::WriteAllText($SETUPSCRIPT, $setupContent, [System.Text.UTF8Encoding]::new($false))
Write-ColorOutput "Created SetupComplete.ps1" "Green"

# ----------------------------------------------------------------------------
# Create autounattend.xml with WORKING local account bypass
# ----------------------------------------------------------------------------
$ANSWERFILE = Join-Path $WORK_DIR "autounattend.xml"
$answerContent = @'
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
            <DynamicUpdate>
                <Enable>false</Enable>
            </DynamicUpdate>
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
            </OOBE>
            <UserAccounts>
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
'@
[System.IO.File]::WriteAllText($ANSWERFILE, $answerContent, [System.Text.UTF8Encoding]::new($false))
Write-ColorOutput "Created autounattend.xml" "Green"

# ----------------------------------------------------------------------------
# Create answer media
# ----------------------------------------------------------------------------
Write-ColorOutput "Creating answer media..." "Cyan"

$ISO_DIR = Join-Path $WORK_DIR "iso_source"
New-Item -ItemType Directory -Path $ISO_DIR -Force | Out-Null
Copy-Item $ANSWERFILE "$ISO_DIR\autounattend.xml" -Force
Copy-Item $SETUPSCRIPT "$ISO_DIR\SetupComplete.ps1" -Force
Write-ColorOutput "Answer media created at: $ISO_DIR" "Green"

# ----------------------------------------------------------------------------
# Create QCOW2 disk
# ----------------------------------------------------------------------------
if (Test-Path $OutputQCOW2Short) {
    Write-ColorOutput "Removing existing disk..." "Yellow"
    Remove-Item $OutputQCOW2Short -Force
}

Write-ColorOutput "Creating QCOW2 disk: $OutputQCOW2Short ($DiskSize)" "Cyan"
& qemu-img create -f qcow2 "$OutputQCOW2Short" "$DiskSize"

# ----------------------------------------------------------------------------
# Launch QEMU
# ----------------------------------------------------------------------------
Write-ColorOutput "" "White"
Write-ColorOutput "============================================================" "Cyan"
Write-ColorOutput "Starting QEMU installation..." "Cyan"
Write-ColorOutput "Local Administrator account is being created automatically" "Green"
Write-ColorOutput "No Microsoft account or network connection required" "Green"
Write-ColorOutput "============================================================" "Cyan"
Write-ColorOutput "" "White"

# Run QEMU directly
& $QEMUPath `
    -accel tcg `
    -cpu qemu64 `
    -smp $CPUCores `
    -m ${RAM_MB}M `
    -drive "file=$OutputQCOW2Short,format=qcow2,if=ide,index=0" `
    -drive "file=$ISOPathShort,if=ide,index=1,media=cdrom" `
    -drive "file=fat:ro:$ISO_DIR,if=ide,index=2,media=cdrom" `
    -vga qxl `
    -display gtk `
    -machine type=pc `
    -rtc base=localtime `
    -boot order=d

# ----------------------------------------------------------------------------
# Check results
# ----------------------------------------------------------------------------
if (Test-Path $OutputQCOW2Short) {
    $size = (Get-Item $OutputQCOW2Short).Length
    Write-ColorOutput "Disk image size: $([math]::Round($size/1GB, 2)) GB" "Cyan"
    
    if ($size -gt 5GB) {
        Write-ColorOutput "Compressing final template..." "Cyan"
        $TEMPLATE = Join-Path $SCRIPT_DIR "windows10-template.qcow2"
        & qemu-img convert -c -O qcow2 "$OutputQCOW2Short" "$TEMPLATE"
        
        Write-ColorOutput "" "Green"
        Write-ColorOutput "============================================================" "Green"
        Write-ColorOutput "SUCCESS!" "Green"
        Write-ColorOutput "============================================================" "Green"
        Write-ColorOutput "Final image: $TEMPLATE" "White"
        Write-ColorOutput "Administrator password: $AdminPassword" "White"
        Write-ColorOutput "============================================================" "Green"
    } else {
        Write-ColorOutput "WARNING: Image size too small - installation failed." "Red"
    }
}

# Cleanup
Write-ColorOutput "Cleaning up temporary files..." "Gray"
Remove-Item -Path $WORK_DIR -Recurse -Force -ErrorAction SilentlyContinue

Write-ColorOutput "Script completed!" "Green"