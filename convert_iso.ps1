# build_win10_qcow2.ps1 - Windows PowerShell script for creating Windows 10 QCOW2 image
# Run as Administrator in PowerShell
# Enable script execution (if not already enabled):
# Run powershell in Administrator, copy/paste 
# Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
# custom parameters: ps1 ".\build_win10_qcow2.ps1 -ISOPath "my-windows.iso" -AdminPassword "MyComplexPass123!" -RAM_MB 16384"  or .\build_win10_qcow2.ps1

param(
    [string]$ISOPath = "windows10_21h2.iso",
    [string]$OutputQCOW2 = "windows10-template.qcow2",
    [string]$DiskSize = "120G",
    [int]$RAM_MB = 8192,
    [int]$CPUCores = 6,
    [string]$AdminPassword = "Password123!",
    [string]$QEMUPath = ""
)

# Set error handling
$ErrorActionPreference = "Stop"

# Colors for output
function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# ----- Find QEMU installation -----
if (-not $QEMUPath) {
    $possiblePaths = @(
        "C:\Program Files\qemu\qemu-system-x86_64.exe",
        "C:\Program Files (x86)\qemu\qemu-system-x86_64.exe",
        (Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue).Source
    )
    
    foreach ($path in $possiblePaths) {
        if ($path -and (Test-Path $path)) {
            $QEMUPath = $path
            break
        }
    }
}

if (-not $QEMUPath -or -not (Test-Path $QEMUPath)) {
    Write-ColorOutput "ERROR: QEMU not found. Please install QEMU first." "Red"
    Write-ColorOutput "Download from: https://qemu.weilnetz.de/w64/" "Yellow"
    exit 1
}

Write-ColorOutput "Using QEMU: $QEMUPath" "Green"

# ----- Create working directory -----
$WORK_DIR = Join-Path $env:TEMP "qemu-build-$([System.Guid]::NewGuid().ToString())"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$ANSWERFILE = Join-Path $SCRIPT_DIR "autounattend.xml"
$POWERSHELL_SCRIPT = Join-Path $SCRIPT_DIR "install-cloudbase.ps1"
$VIRTIO_WIN_ISO = Join-Path $SCRIPT_DIR "virtio-win.iso"

New-Item -ItemType Directory -Path $WORK_DIR -Force | Out-Null

# Check for virtio-win.iso
$virtioExists = Test-Path $VIRTIO_WIN_ISO
if (-not $virtioExists) {
    Write-ColorOutput "NOTE: virtio-win.iso not found. This is optional - Windows will use IDE drivers." "Yellow"
}

# ----- Sanity checks -----
if (-not (Test-Path $ISOPath)) {
    Write-ColorOutput "ERROR: ISO not found at $ISOPath" "Red"
    Write-ColorOutput "Current directory: $(Get-Location)" "Yellow"
    Get-ChildItem *.iso -ErrorAction SilentlyContinue | ForEach-Object { Write-ColorOutput "  Found: $($_.Name)" "Yellow" }
    exit 1
}

# ----- 1. Create the QCOW2 disk -----
Write-ColorOutput "Creating QCOW2 disk: $OutputQCOW2 ($DiskSize)" "Cyan"
& qemu-img create -f qcow2 "$OutputQCOW2" "$DiskSize"

# ----- 2. Generate the PowerShell script -----
@'
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
'@ | Out-File -FilePath $POWERSHELL_SCRIPT -Encoding ASCII

# ----- 3. Generate autounattend.xml with Microsoft account bypass -----
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
'@ | Out-File -FilePath $ANSWERFILE -Encoding ASCII

# Convert to Windows line endings (CRLF)
(Get-Content $ANSWERFILE) -join "`r`n" | Set-Content $ANSWERFILE -NoNewline

# ----- 4. Create answer ISO using PowerShell -----
Write-ColorOutput "Creating answer ISO..." "Cyan"
$ANSWER_ISO = Join-Path $WORK_DIR "answer.iso"

try {
    $iso = New-Object -ComObject IMAPI2FS.MsftIsoImage
    $iso.VolumeName = "AUTORUN"
    $root = $iso.Root
    
    # Add autounattend.xml
    $root.AddFile($ANSWERFILE, $ANSWERFILE)
    
    # Create directory structure and add PowerShell script
    $scriptsDir = $root.AddDirectory("Windows")
    $scriptsDir = $scriptsDir.AddDirectory("Setup")
    $scriptsDir = $scriptsDir.AddDirectory("Scripts")
    $scriptsDir.AddFile($POWERSHELL_SCRIPT, $POWERSHELL_SCRIPT)
    
    # Write ISO to file
    $stream = [System.IO.File]::OpenWrite($ANSWER_ISO)
    $iso.WriteToStream($stream)
    $stream.Close()
    
    Write-ColorOutput "ISO created successfully" "Green"
} catch {
    Write-ColorOutput "PowerShell ISO creation failed: $_" "Red"
    Write-ColorOutput "Falling back to folder method..." "Yellow"
    
    $isoFolder = Join-Path $WORK_DIR "cdrom"
    New-Item -ItemType Directory -Path $isoFolder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $isoFolder "Windows\Setup\Scripts") -Force | Out-Null
    Copy-Item $ANSWERFILE (Join-Path $isoFolder "autounattend.xml")
    Copy-Item $POWERSHELL_SCRIPT (Join-Path $isoFolder "Windows\Setup\Scripts\")
    $ANSWER_ISO = $isoFolder
}

# ----- 5. Launch QEMU -----
Write-ColorOutput "" "White"
Write-ColorOutput "=========================================" "Cyan"
Write-ColorOutput "Starting QEMU installation..." "Cyan"
Write-ColorOutput "This will take 30-60 minutes" "Yellow"
Write-ColorOutput "Microsoft account login has been bypassed" "Green"
Write-ColorOutput "Local Administrator account will be used" "Green"
Write-ColorOutput "=========================================" "Cyan"
Write-ColorOutput "" "White"

# Build QEMU command arguments
$qemuArgs = @(
    "-cpu", "qemu64",
    "-smp", $CPUCores,
    "-m", $RAM_MB,
    "-drive", "file=`"$OutputQCOW2`",format=qcow2,if=ide,index=0",
    "-drive", "file=`"$ISOPath`",format=raw,if=ide,index=1,media=cdrom"
)

# Add answer ISO
if (Test-Path $ANSWER_ISO) {
    if ((Get-Item $ANSWER_ISO).PSIsContainer) {
        $qemuArgs += "-drive", "file=fat:rw:`"$ANSWER_ISO`",format=raw,if=ide,index=2,media=cdrom"
    } else {
        $qemuArgs += "-drive", "file=`"$ANSWER_ISO`",format=raw,if=ide,index=2,media=cdrom"
    }
}

# Add virtio-win ISO if available
if ($virtioExists) {
    $qemuArgs += "-drive", "file=`"$VIRTIO_WIN_ISO`",format=raw,if=ide,index=3,media=cdrom"
}

# Windows-optimized flags
$qemuArgs += @(
    "-vga", "qxl",
    "-display", "gtk",
    "-machine", "type=pc",
    "-usb",
    "-device", "usb-tablet",
    "-rtc", "base=localtime"
)

Write-ColorOutput "Running: $QEMUPath $($qemuArgs -join ' ')" "Yellow"
Write-ColorOutput "" "White"

# Start QEMU process
$qemuProcess = Start-Process -FilePath $QEMUPath -ArgumentList $qemuArgs -PassThru -NoNewWindow

Write-ColorOutput "QEMU is running. Installation will complete automatically." "Green"
Write-ColorOutput "The VM window will close when Sysprep finishes." "Yellow"

# ----- 6. Wait for completion -----
Write-ColorOutput "Waiting for Windows installation and Sysprep to finish..." "Cyan"
$qemuProcess.WaitForExit()

# ----- 7. Compress the final image -----
Write-ColorOutput "Compressing final template..." "Cyan"
$TEMPLATE = [System.IO.Path]::ChangeExtension($OutputQCOW2, "-template.qcow2")
& qemu-img convert -c -O qcow2 "$OutputQCOW2" "$TEMPLATE"

# ----- 8. Cleanup -----
Write-ColorOutput "Cleaning up temporary files..." "Cyan"
Remove-Item -Path $WORK_DIR -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $ANSWERFILE -Force -ErrorAction SilentlyContinue
Remove-Item -Path $POWERSHELL_SCRIPT -Force -ErrorAction SilentlyContinue

Write-ColorOutput "" "White"
Write-ColorOutput "=============================================" "Green"
Write-ColorOutput "SUCCESS!" "Green"
Write-ColorOutput "Final image: $TEMPLATE" "White"
Write-ColorOutput "Administrator password: $AdminPassword" "White"
Write-ColorOutput "" "White"
Write-ColorOutput "To test the image:" "Yellow"
Write-ColorOutput "& `"$QEMUPath`" -m 4096 -drive file=$TEMPLATE,format=qcow2,if=ide -vga qxl -display gtk" "White"
Write-ColorOutput "=============================================" "Green"