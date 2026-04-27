# install-cloudbase.ps1 - First boot script
Write-Host "Installing Cloudbase-Init..." -ForegroundColor Green

# Download Cloudbase-Init
$url = "https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi"
$output = "$env:TEMP\CloudbaseInitSetup.msi"
Write-Host "Downloading Cloudbase-Init from $url..."
Invoke-WebRequest -Uri $url -OutFile $output -UseBasicParsing

# Install silently
Write-Host "Installing Cloudbase-Init..."
$process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$output`" /quiet /norestart LOGGINGLEVEL=3 Username=`"Administrator`" RunCloudbaseInitServiceAsLocalSystem=1" -Wait -PassThru

Start-Sleep -Seconds 5

# Set Administrator password
Write-Host "Configuring Administrator account..."
net user Administrator "Password123!" /logonpasswordchg:no 2>$null
wmic UserAccount where "Name='Administrator'" set PasswordExpires=False 2>$null

# Enable WinRM
Write-Host "Configuring WinRM..."
winrm quickconfig -q -force 2>$null
winrm set winrm/config/service/auth '@{Basic="true"}' 2>$null
winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>$null

# Configure cloudbase-init
$conf = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"
if (Test-Path $conf) {
    Write-Host "Configuring cloudbase-init..."
    $content = Get-Content $conf
    $content = $content -replace 'metadata_services=.*', 'metadata_services=cloudbaseinit.metadata.services.httpservice.HttpService'
    $content | Set-Content $conf
    Add-Content $conf "`ninject_admin_password=true"
    Add-Content $conf "`nadmin_password=Password123!"
}

# Restart service
Restart-Service CloudbaseInit -ErrorAction SilentlyContinue

# Run Sysprep
Write-Host "Running Sysprep to generalize the image..." -ForegroundColor Green
& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet

Write-Host "Sysprep completed. VM will shut down." -ForegroundColor Green
