# Cleanup for Sysprep - Run this BEFORE opening Cloudbase-Init Config & Run Sysprep
# Fixes common "Sysprep was not able to validate your Windows installation" errors

Write-Host 'Cleaning pending updates, apps, logs...' -ForegroundColor Green

# 1. Stop Windows Update & delete pending.xml
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
rm -Force "$env:SYSTEMROOT\SoftwareDistribution" -Recurse -ErrorAction SilentlyContinue
rm -Force "$env:SYSTEMROOT\System32\config\TXR*.log" -Recurse -ErrorAction SilentlyContinue
rm -Force "$env:WINDIR\Panther\setupact.log" -ErrorAction SilentlyContinue
rm -Force "$env:WINDIR\Panther\setuperr.log" -ErrorAction SilentlyContinue

# 2. Clear event logs
wevtutil.exe el | Foreach-Object {wevtutil.exe cl "$_"} 2>$null

# 3. Reset Sysprep state & registry
reg delete "HKLM\SYSTEM\Setup\Status\SysprepStatus" /f 2>$null | Out-Null
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\SysprepStatus" /f 2>$null | Out-Null
reg add "HKLM\SYSTEM\Setup\Status\SysprepStatus" /v State /t REG_DWORD /d 7 /f 2>$null | Out-Null

# 4. Remove pending apps
Get-AppxPackage -AllUsers | Remove-AppxPackage -ErrorAction SilentlyContinue

# 5. Clear temp & pagefile
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
wmic pagefile delete /f 2>$null | Out-Null
wmic computersystem where name="%computername%" set AutomaticManagedPagefile=False 2>$null | Out-Null

Write-Host 'Cleanup complete. Now safe to run Cloudbase-Init Sysprep.' -ForegroundColor Cyan
Write-Host 'Open Cloudbase-Init Config → Generate Password → Run Sysprep → Finish → Shutdown.' -ForegroundColor Yellow
