#!/bin/bash
set -e

CLUSTER_INTERFACE="eth0"
CLUSTER_IP="192.168.50.1/24"
CLUSTER_GATEWAY="192.168.50.1"
CLUSTER_DHCP_RANGE="192.168.50.100,192.168.50.200"

INTERNET_INTERFACE="wlan0"

NODE_NAME="rpi2"
NFS_ROOT="/srv/nfs/${NODE_NAME}"
TFTP_ROOT="/srv/tftp"

if [ "$(id -u)" -ne "0" ]; then
   echo "This script must be run as root. Please use sudo." 1>&2
   exit 1
fi

echo ">>> [1/7] Updating and installing required packages..."
apt update
apt install -y dnsmasq nfs-kernel-server iptables-persistent kpartx curl wget xz-utils rsync

echo ">>> [2/7] Configuring static IP for the cluster network on ${CLUSTER_INTERFACE}..."
nmcli con delete "cluster-net" >/dev/null 2>&1 || true
nmcli con add type ethernet con-name "cluster-net" ifname "${CLUSTER_INTERFACE}" ipv4.method manual ipv4.addresses "${CLUSTER_IP}"
nmcli con up "cluster-net"

echo ">>> [3/7] Enabling IP forwarding and configuring NAT..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf

iptables -t nat -A POSTROUTING -o "${INTERNET_INTERFACE}" -j MASQUERADE
iptables -A FORWARD -i "${CLUSTER_INTERFACE}" -o "${INTERNET_INTERFACE}" -j ACCEPT
iptables -A FORWARD -i "${INTERNET_INTERFACE}" -o "${CLUSTER_INTERFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
netfilter-persistent save

echo ">>> [4/7] Preparing compute node filesystem directories..."
mkdir -p "${NFS_ROOT}"
mkdir -p "${TFTP_ROOT}"

chmod 777 /srv/nfs/rpi2

TMPDIR=$(mktemp -d)
trap 'rm -rf -- "$TMPDIR"' EXIT
cd "$TMPDIR"

echo ">>> [5/7] Downloading and extracting Raspberry Pi OS..."
wget -q --show-progress -O raspios_lite_latest.img.xz https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64-lite.img.xz
xz -d raspios_lite_latest.img.xz
IMG_FILE=$(ls *.img)

echo "Mounting image and copying files..."
kpartx -a -v "$IMG_FILE"
sleep 5
mkdir -p img_boot img_root
mount /dev/mapper/loop0p1 img_boot
mount /dev/mapper/loop0p2 img_root

rsync -xa img_boot/ "$TFTP_ROOT/"
rsync -xa img_root/ "$NFS_ROOT/"

umount img_boot img_root
kpartx -d "$IMG_FILE"
cd /

echo ">>> [6/7] Modifying filesystem for network boot..."
CMDLINE="console=serial0,115200 console=tty1 root=/dev/nfs nfsroot=${CLUSTER_GATEWAY}:${NFS_ROOT},vers=4.1,proto=tcp rw ip=dhcp rootwait"
echo "$CMDLINE" > "${TFTP_ROOT}/cmdline.txt"

sed -i 's/^\(PARTUUID=.*\)/#\1/g' "${NFS_ROOT}/etc/fstab"
echo "${CLUSTER_GATEWAY}:${TFTP_ROOT} /boot nfs defaults,vers=4.1,proto=tcp 0 0" >> "${NFS_ROOT}/etc/fstab"

touch "${TFTP_ROOT}/ssh"

echo ">>> [7/7] Configuring and starting services..."
echo "${NFS_ROOT} ${CLUSTER_IP%/*}0(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
echo "${TFTP_ROOT} ${CLUSTER_IP%/*}0(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
exportfs -ra
systemctl restart nfs-kernel-server

cat << EOF > /etc/dnsmasq.d/01-netboot.conf
interface=${CLUSTER_INTERFACE}
bind-interfaces

dhcp-range=${CLUSTER_DHCP_RANGE},255.255.255.0,12h

dhcp-option=option:router,${CLUSTER_GATEWAY}
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8

enable-tftp
tftp-root=${TFTP_ROOT}

pxe-service=0,"Raspberry Pi Boot"

log-dhcp
EOF

mkdir -p /etc/systemd/system/dnsmasq.service.d/
cat << EOF > /etc/systemd/system/dnsmasq.service.d/wait-for-network.conf
[Unit]
After=network-online.target
Wants=network-online.target
EOF

systemctl daemon-reload
systemctl restart dnsmasq

echo ""
echo "✅ Head node setup is complete!"
echo "The system is ready to netboot a compute node named '${NODE_NAME}'."
