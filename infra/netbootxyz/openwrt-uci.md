# OpenWrt (sharon, 192.168.1.1) — declarative UCI change sheet
#
# Context (archive-validated): sharon is a dumb WAP + DHCP relay. It hands the
# LAN gateway (option 3) and DNS (option 6) to markslone, publishes the PXE
# next-server (option 66) + bootfile (option 67), and clamps leases to 30
# minutes so the LAN fails back to ISP routing fast if markslone dies.
# Dropbear root SSH is passwordless on LAN — connect via `ssh root@192.168.1.1`.
#
# ## 1. Backup FIRST (archive t72 procedure)
#   ssh root@192.168.1.1 "sysupgrade -b /tmp/sharon-backup.tar.gz" && \
#   scp root@192.168.1.1:/tmp/sharon-backup.tar.gz ~/backups/
# Restore: scp back, then `sysupgrade -r /tmp/sharon-backup.tar.gz`.
#
# ## 2. Gateway + DNS redirect to markslone
#   uci set dhcp.lan.dhcp_option='3,192.168.1.179 6,192.168.1.179,1.1.1.1'
#   uci set dhcp.lan.leasetime='30m'
#
# ## 3. PXE next-server + bootfile (netboot.xyz on markslone)
#   uci add_list dhcp.lan.boot_server='192.168.1.179'
#   uci set dhcp.lan.pxe_service='x86-64_EFI,AcidWurx NetBoot,netboot.xyz.efi,192.168.1.179'
#   (dnsmasq pass-through options on modern OpenWrt/apk builds:)
#   uci add_list dhcp.lan.dhcp_option='66,192.168.1.179'
#   uci add_list dhcp.lan.dhcp_option='67,netboot.xyz.efi'
#
# ## 4. Commit + restart
#   uci commit dhcp && /etc/init.d/dnsmasq restart
#
# ## 5. Cake SQM (bufferbloat guard — keep existing config; verify only)
#   uci show sqm | grep -E 'qdisc|enabled'
#
# ## 6. Silence legacy cron noise (archive t84 fix)
#   sed -i '/ssh-keyscan/d' /usr/local/bin/router-backup.sh 2>/dev/null || true
#
# Verification after apply (from a LAN client):
#   ip route | grep default          -> via 192.168.1.179
#   resolvectl status | grep DNS     -> 192.168.1.179 1.1.1.1
#   PXE boot any node                -> AcidWurx NetBoot menu appears
