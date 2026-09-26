#!/bin/bash
# =============================================================================
# /etc/wireguard/wgcf-up.sh — VALIDATED policy-routing hook (archive t190).
# Order is law (AI_README Law 2): bypass rules (prio 50-52) MUST precede the
# LAN breakout rule (prio 100). NAT is source-filtered to the LAN only.
set -e
TABLE=100
IF=wgcf

# 1. Clean old rules (idempotent re-application)
ip route flush table $TABLE 2>/dev/null || true

# 2. Bypass rules — higher priority (lower number) than LAN breakout
ip rule add to 100.64.0.0/10 lookup main priority 50 2>/dev/null || true
ip rule add to 192.168.1.0/24 lookup main priority 51 2>/dev/null || true
ip rule add to 172.16.0.0/12 lookup main priority 52 2>/dev/null || true

# 3. Outbound breakout: ONLY LAN sources go to wgcf
ip route add default dev $IF table $TABLE
ip rule add from 192.168.1.0/24 lookup $TABLE priority 100

# 4. NAT only LAN-sourced traffic (never NAT mesh traffic)
iptables -t nat -C POSTROUTING -s 192.168.1.0/24 -o $IF -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -o $IF -j MASQUERADE

# 5. Forwarding for LAN only
iptables -C FORWARD -s 192.168.1.0/24 -o $IF -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s 192.168.1.0/24 -o $IF -j ACCEPT

ip route flush cache
