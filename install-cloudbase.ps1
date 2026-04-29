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
