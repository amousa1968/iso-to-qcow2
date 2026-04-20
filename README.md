# iso-to-qcow2
Convert iso-to-qcow2
(in VM setup screen):

Click "Load driver"
Select VirtIO CD (D:\ or E:)
Go to viostor\w10\amd64 → select viostor.inf → OK
QCOW2 disk appears → install
Script provides all needed:

VirtIO drivers CD
120GB QCOW2 (virtio disk)
autounattend.xml (auto-setup)
CloudbaseInit MSI (auto-installs post-boot)
Post-install: Admin/Pasword123! auto-login, Cloudbase-Init installs.

Run Sysprep: Open Cloudbase Config → "Run Sysprep" → template ready.
