#!/bin/bash
set -e

# Configuration variables
CLUSTER_IP="192.168.2.1/24"
CLUSTER_GATEWAY="192.168.2.1"
CLUSTER_DHCP_RANGE="192.168.2.100,192.168.2.200"
INTERNET_INTERFACE="wlan0"
CLUSTER_INTERFACE="eth0"

# Ensure the script is run as root
if [ "$(id -u)" -ne "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

echo ">>> [1/5] Updating and installing required packages..."
apt update
apt install -y dnsmasq iptables-persistent

echo ">>> [2/5] Verifying network interfaces..."
if ! ip link show "$CLUSTER_INTERFACE" >/dev/null 2>&1; then
    echo "Error: Interface $CLUSTER_INTERFACE not found." 1>&2
    exit 1
fi
if ! ip link show "$INTERNET_INTERFACE" >/dev/null 2>&1; then
    echo "Error: Interface $INTERNET_INTERFACE not found." 1>&2
    exit 1
fi

echo ">>> [3/5] Configuring static IP for the cluster network on ${CLUSTER_INTERFACE}..."
nmcli con delete "cluster-net" >/dev/null 2>&1 || true
nmcli con add type ethernet con-name "cluster-net" ifname "${CLUSTER_INTERFACE}" ipv4.method manual ipv4.addresses "${CLUSTER_IP}"
nmcli con up "cluster-net"

echo ">>> [4/5] Enabling IP forwarding and configuring NAT..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf
iptables -t nat -A POSTROUTING -o "${INTERNET_INTERFACE}" -j MASQUERADE
iptables -A FORWARD -i "${CLUSTER_INTERFACE}" -o "${INTERNET_INTERFACE}" -j ACCEPT
iptables -A FORWARD -i "${INTERNET_INTERFACE}" -o "${CLUSTER_INTERFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
netfilter-persistent save

echo ">>> [5/5] Configuring and starting DHCP service..."
cat << EOF > /etc/dnsmasq.d/01-cluster-dhcp.conf
interface=${CLUSTER_INTERFACE}
bind-interfaces
dhcp-range=${CLUSTER_DHCP_RANGE},255.255.255.0,12h
dhcp-option=option:router,${CLUSTER_GATEWAY}
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
log-dhcp
EOF

mkdir -p /etc/systemd/system/dnsmasq.service.d/
cat << EOF > /etc/systemd/system/dnsmasq.service.d/wait-for-network.conf
[Unit]
After=network-online.target
Wants=network-online.target
EOF

systemctl daemon-reload
if ! systemctl restart dnsmasq; then
    echo "Error: Failed to restart dnsmasq. Checking logs..." 1>&2
    systemctl status dnsmasq.service
    journalctl -xeu dnsmasq.service
    exit 1
fi

echo ""
echo "✅ Setup is complete!"
echo "The system is configured to provide DHCP and internet access to the compute node via ${CLUSTER_INTERFACE}."
