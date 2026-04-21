# Post-Windows Install: VirtIO Network/Storage Drivers
# Run as Administrator in VM after first login

$virtioPath = 'D:\'  # VirtIO CD (adjust if E:)
$drivers = @(
    @{name='NetKVM'; path='NetKVM\w10\amd64'; inf='netkvm.inf'},
    @{name='viostor'; path='viostor\w10\amd64'; inf='viostor.inf'},
    @{name='vioscsi'; path='vioscsi\w10\amd64'; inf='vioscsi.inf'},
    @{name='qxldod'; path='qxldod\w10\amd64'; inf='qxldod.inf'},
    @{name='Balloon'; path='Balloon\w10\amd64'; inf='Balloon.inf'}
)

Write-Host 'Installing VirtIO Drivers...' -ForegroundColor Green
foreach ($driver in $drivers) {
    $infPath = Join-Path $virtioPath $driver.path $driver.inf
    if (Test-Path $infPath) {
        pnputil /add-driver $infPath /install
        Write-Host "Installed $($driver.name)" -ForegroundColor Yellow
    }
}

Write-Host 'Reboot to apply: shutdown /r /t 0' -ForegroundColor Cyan
