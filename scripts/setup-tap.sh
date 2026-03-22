#!/bin/bash
# Set up TAP networking for Flint VMs.
# Creates a TAP device with NAT so guests can reach the internet.
# Requires: sudo
#
# Usage: sudo ./scripts/setup-tap.sh [tap_name]
#   Default tap_name: tap0

set -euo pipefail

TAP="${1:-tap0}"
BRIDGE_IP="172.16.0.1"
GUEST_SUBNET="172.16.0.0/24"

# Get the default outbound interface
OUTIF="$(ip route | awk '/^default/ {print $5; exit}')"

echo "=== Flint TAP Setup ==="
echo "TAP device: $TAP"
echo "Bridge IP:  $BRIDGE_IP"
echo "Outbound:   $OUTIF"

# Create TAP device owned by the calling user
REAL_USER="${SUDO_USER:-$(whoami)}"
ip tuntap add dev "$TAP" mode tap user "$REAL_USER" 2>/dev/null || true
ip addr add "$BRIDGE_IP/24" dev "$TAP" 2>/dev/null || true
ip link set "$TAP" up

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# NAT masquerade
iptables -t nat -C POSTROUTING -s "$GUEST_SUBNET" -o "$OUTIF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$GUEST_SUBNET" -o "$OUTIF" -j MASQUERADE

# Allow forwarding for this subnet
iptables -C FORWARD -i "$TAP" -o "$OUTIF" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$TAP" -o "$OUTIF" -j ACCEPT
iptables -C FORWARD -i "$OUTIF" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$OUTIF" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Done. Guest should use:"
echo "  ip addr add 172.16.0.2/24 dev eth0"
echo "  ip route add default via 172.16.0.1"
echo ""
echo "Pass --tap $TAP to flint to use this device."
