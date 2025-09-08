#!/bin/bash
set -e

if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

apt update
apt install -y network-manager dnsmasq tftpd-hpa nfs-kernel-server iptables-persistent

nmcli con delete eth0 || true
nmcli con add type ethernet con-name "eth0" ifname eth0 ipv4.method manual ipv4.addresses 192.168.2.1/24
nmcli con up eth0

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf

iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables-save > /etc/iptables/rules.v4

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null || true
cat > /etc/dnsmasq.d/netboot.conf <<EOF
interface=eth0
bind-interfaces

dhcp-range=192.168.2.100,192.168.2.150,255.255.255.0,12h

dhcp-host=2c:cf:67:59:a8:ab,192.168.2.2,infinite

dhcp-option=option:router,192.168.2.1
dhcp-option=option:dns-server,1.1.1.1
EOF

systemctl restart dnsmasq

echo "✅ Setup complee"
