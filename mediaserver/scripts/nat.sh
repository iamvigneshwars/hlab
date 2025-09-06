#!/bin/bash
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

apt update
apt install network-manager network-manager-gnome dnsmasq tftpd-hpa nfs-kernel-server iptables-persistent -y

nmcli con add type ethernet con-name "eth0" ifname eth0 ipv4.method manual ipv4.addresses 192.168.2.1/24
nmcli con up eth0

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables-save > /etc/iptables/rules.v4

echo -e "interface=eth0\ndhcp-range=192.168.2.100,192.168.2.150,12h" >> /etc/dnsmasq.conf
systemctl restart dnsmasq
