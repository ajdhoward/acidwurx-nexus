#!/bin/bash
# /etc/wireguard/wgcf-down.sh — mirror cleanup of wgcf-up.sh (validated).
# Strict mode is safe here: every rule removal is guarded with || true.
set -euo pipefail
TABLE=100
IF=wgcf
ip rule del to 100.64.0.0/10 lookup main priority 50 2>/dev/null || true
ip rule del to 192.168.1.0/24 lookup main priority 51 2>/dev/null || true
ip rule del to 172.16.0.0/12 lookup main priority 52 2>/dev/null || true
ip rule del from 192.168.1.0/24 lookup $TABLE priority 100 2>/dev/null || true
ip route flush table $TABLE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 192.168.1.0/24 -o $IF -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -s 192.168.1.0/24 -o $IF -j ACCEPT 2>/dev/null || true
ip route flush cache
