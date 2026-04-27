# Cleanup for Sysprep - Run this BEFORE opening Cloudbase-Init Config & Run Sysprep
# Fixes Platform9 "Sysprep was not able to validate your Windows installation" errors
# Root cause: Windows Update / TiWorker / background services still running

Write-Host 'Stopping all background services for sysprep...' -ForegroundColor Green

# 1. Stop Windows Update and ALL related services
$services = @('wuauserv', 'BITS', 'dosvc', 'UsoSvc', 'WaaSMedicSvc', 'cryptSvc', 'msiserver')
foreach ($svc in $services) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}

# 2. Wait for servicing processes to finish (TiWorker, TrustedInstaller)
Write-Host 'Waiting for background processes...' -ForegroundColor Yellow
$timeout = 300
$elapsed = 0
while (($proc = Get-Process | Where-Object {$_.ProcessName -match 'TiWorker|TrustedInstaller'})) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    if ($elapsed -ge $timeout) { break }
}

# 3. Kill any remaining update processes
Get-Process | Where-Object {$_.ProcessName -match 'TiWorker|TrustedInstaller|wuauclt|SetupHost'} | Stop-Process -Force -ErrorAction SilentlyContinue

# 4. Delete pending updates and Windows Update cache
Remove-Item "$env:SYSTEMROOT\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SYSTEMROOT\System32\config\TXR*.log" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:WINDIR\Panther\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

# 5. Clear ALL event logs
wevtutil el | ForEach-Object {wevtutil cl "$_" 2>$null}

# 6. Remove AppX packages (major sysprep blocker on Win11)
Write-Host 'Removing AppX packages...' -ForegroundColor Yellow
Get-AppxPackage -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue
Get-AppxProvisionedPackage -Online | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue

# 7. Remove Windows Update registry keys
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate" /f 2>$null | Out-Null
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /f 2>$null | Out-Null

# 8. Reset sysprep status
reg delete "HKLM\SYSTEM\Setup\Status\SysprepStatus" /f 2>$null | Out-Null
reg add "HKLM\SYSTEM\Setup\Status\SysprepStatus" /v State /t REG_DWORD /d 7 /f 2>$null | Out-Null

# 9. Set automatic pagefile (prevents sysprep error)
wmic computersystem where name="%computername%" set AutomaticManagedPagefile=True 2>$null | Out-Null

Write-Host 'Cleanup complete. System ready for Cloudbase-Init Sysprep.' -ForegroundColor Cyan
Write-Host 'Open Cloudbase-Init Config Tool → Run Sysprep → Finish → Shutdown.' -ForegroundColor Yellow
