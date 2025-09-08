#!/bin/bash

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

apt update
apt install parted -y

parted /dev/nvme0n1 <<EOF
mklabel gpt
mkpart primary fat32 1MiB 513MiB
mkpart primary ext4 513MiB 128GiB
mkpart primary ext4 128GiB 100%
quit
EOF

mkfs.vfat -F 32 /dev/nvme0n1p1
mkfs.ext4 /dev/nvme0n1p2
mkfs.ext4 /dev/nvme0n1p3

mkdir -p /mnt/boot /mnt/root
mount /dev/nvme0n1p1 /mnt/boot
mount /dev/nvme0n1p2 /mnt/root
mkdir -p /mnt/root/boot/firmware
mount /dev/nvme0n1p1 /mnt/root/boot/firmware

rsync -axv /boot/firmware/ /mnt/boot/
rsync -axv --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found} / /mnt/root/

BOOT_UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)
ROOT_UUID=$(blkid -s UUID -o value /dev/nvme0n1p2)
cat <<EOF > /mnt/root/etc/fstab
UUID=$BOOT_UUID  /boot/firmware  vfat  defaults,noatime  0  2
UUID=$ROOT_UUID  /  ext4  defaults,noatime  0  1
EOF

ROOT_PARTUUID=$(blkid -s PARTUUID -o value /dev/nvme0n1p2)
sed -i "s/root=PARTUUID=[0-9a-f-]* /root=PARTUUID=$ROOT_PARTUUID /" /mnt/boot/cmdline.txt

umount /mnt/root/boot/firmware
umount /mnt/root
umount /mnt/boot

rpi-eeprom-update -a

echo "Setup complete. Power off, remove SD card, and reboot to boot from NVMe."
