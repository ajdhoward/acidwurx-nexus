#!/usr/bin/env bash
# =============================================================================
# 02_lan_iot_firmware_sweep.sh — read-only LAN sweep: live-host discovery
# (parallel ping + ARP/neighbour table), service-port fingerprinting
# (HA 8123, MQTT 1883, and the AcidWurx service catalog), MAC OUI vendor
# identification with ESP8266/ESP32 (Espressif) flagging for ESPHome/OpenWrt
# firmware staging. Connect-only scanning — no packets beyond ICMP echo and
# TCP SYN via /dev/tcp. Writes 02_lan_iot_firmware_sweep_result.json.
# =============================================================================
set -euo pipefail

OUT_DIR="${NEXO_OUT_DIR:-.}"
mkdir -p "${OUT_DIR}"
LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"
BASE="${LAN_SUBNET%.*}"
SWEEP_FILE="$(mktemp)"
HOSTS_FILE="$(mktemp)"
PORTS_FILE="$(mktemp)"
trap 'rm -f "${SWEEP_FILE}" "${HOSTS_FILE}" "${PORTS_FILE}"' EXIT

echo "[02] sweeping ${LAN_SUBNET} (read-only ICMP + TCP connect)"

# --- 1. Parallel ping sweep (batched, 1s timeout) ------------------------------
for i in $(seq 1 254); do
  (
    ping -c 1 -W 1 "${BASE}.${i}" >/dev/null 2>&1 && echo "${BASE}.${i}" >> "${SWEEP_FILE}" || true
  ) &
  if (( i % 64 == 0 )); then wait; fi
done
wait

# --- 2. Merge ARP/neighbour table (catches hosts that block ICMP) ---------------
{
  ip neigh show 2>/dev/null | awk '$NF != "FAILED" && $1 ~ /^'"${BASE##*.}"'$|'"${BASE}"'\./ {print $1}' || true
  arp -an 2>/dev/null | grep -oE "${BASE}\.[0-9]+" || true
  cat "${SWEEP_FILE}" 2>/dev/null || true
} | sort -u -t. -k4,4n > "${HOSTS_FILE}"

# --- 3. Service-port fingerprints per live host --------------------------------
# port:label pairs from the AcidWurx service catalog (ARCHITECTURE.md §2)
PORT_LABELS="22:ssh 53:dns 69:tftp 80:http 443:https 554:rtsp 1883:mqtt 3000:openwebui 3001:adguard-admin 3128:proxy 4000:litellm 5353:mdns 5678:n8n 8080:http-alt 8081:searxng-plane 8096:jellyfin 8100:paperless 8123:homeassistant 8443:https-alt 9000:portainer-wol 11434:ollama 49152:upnp"
while read -r host; do
  [ -z "${host}" ] && continue
  found=""
  IFS=' ' read -r -a pairs <<< "${PORT_LABELS}"
  for pair in "${pairs[@]}"; do
    port="${pair%%:*}"
    label="${pair##*:}"
    if timeout 1 bash -c "echo > /dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      found="${found}${port}:${label} "
    fi
  done
  if [ -n "${found}" ]; then
    echo "${host} ${found}" >> "${PORTS_FILE}"
  fi
done < "${HOSTS_FILE}"

# --- 4. MAC table (ip neigh preferred; arp fallback) ----------------------------
MAC_FILE="$(mktemp)"
trap 'rm -f "${SWEEP_FILE}" "${HOSTS_FILE}" "${PORTS_FILE}" "${MAC_FILE}"' EXIT
{
  ip neigh show 2>/dev/null | awk 'NF>=5 && $3 == "lladdr" {print $1, $4}' || true
  arp -an 2>/dev/null | awk -F'[() ]+' '/ether|incomplete/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) ip=$i; print ip, $NF}' || true
} | sort -u > "${MAC_FILE}"

# --- 5. Structured JSON emission (python3 converter) -----------------------------
python3 - "${HOSTS_FILE}" "${PORTS_FILE}" "${MAC_FILE}" "${OUT_DIR}" <<'PYEOF'
import datetime, json, os, sys

hosts_file, ports_file, mac_file, out_dir = sys.argv[1:5]

# OUI vendor table — IoT/fleet-relevant prefixes (archive: Espressif targets for
# ESPHome staging; TP-Link = sharon router; Intel = markslone NIC).
OUI = {
    "5C:CF:7F": "Espressif (ESP8266/ESP32)", "18:FE:34": "Espressif (ESP8266/ESP32)",
    "24:0A:C4": "Espressif (ESP8266/ESP32)", "30:AE:A4": "Espressif (ESP8266/ESP32)",
    "A4:CF:12": "Espressif (ESP8266/ESP32)", "84:0D:2E": "Espressif (ESP8266/ESP32)",
    "2C:F4:32": "Espressif (ESP8266/ESP32)", "BC:DD:C2": "Espressif (ESP8266/ESP32)",
    "B8:27:EB": "Raspberry Pi Foundation", "DC:A6:32": "Raspberry Pi Trading",
    "E4:5F:01": "Raspberry Pi Trading", "28:EE:52": "TP-Link (sharon/openwrt-primary)",
    "04:7D:7B": "Intel Corporate (markslone NIC)", "00:15:5D": "Microsoft Hyper-V",
    "00:1A:11": "Google", "3C:5A:B4": "Google", "00:1D:0F": "TP-Link",
    "50:C7:BF": "TP-Link", "AC:84:C6": "TP-Link", "D8:0D:17": "TP-Link",
    "74:83:C2": "Apple", "F0:18:98": "Apple", "00:11:32": "Synology",
    "00:15:17": "Intel", "3C:FD:FE": "Intel", "B4:2E:99": "Giga-Byte (NUCs)",
    "00:E0:4C": "Realtek", "52:54:00": "QEMU/KVM virtual NIC",
    "08:00:27": "VirtualBox", "00:0C:29": "VMware", "DC:A4:CA": "Apple",
    "68:9E:16": "Amazon (Echo/FireTV)", "44:65:0D": "Amazon", "18:B4:30": "Nest Labs",
    "64:16:66": "Nest Labs", "00:17:88": "Philips Hue (Signify)", "EC:B5FA": "Xiaomi",
    "78:11:DC": "Xiaomi", "04:4F:AA": "Ruckus", "FC:EC:DA": "Ubiquiti",
    "78:8A:20": "Ubiquiti", "00:1E:58": "D-Link", "C0:4A:00": "TP-Link",
    "5C:E5:0C": "Sonoff (ITEAD)", "E8:DB:84": "Le Shi (LeEco)",
    "10:5A:F7": "Shelly (Allterco)", "8C:F6:81": "Silicon Labs (Z-Wave/ZigBee)",
    "00:12:4B": "Texas Instruments (ZigBee)", "94:B9:7E": "EFR32 (ZigBee/Z-Wave)",
    "30:B5:F1": "Aithrit (BLE)", "F4:CE:36": "Nordic Semiconductor (BLE)",
    "2C:11:65": "Silicon Labs", "00:23:7A": "RIM/Blackberry", "00:1C:42": "Parallels",
}

hosts = [line.strip() for line in open(hosts_file) if line.strip()]
ports = {}
for line in open(ports_file):
    parts = line.split()
    if len(parts) >= 2:
        ports[parts[0]] = parts[1:]
macs = {}
for line in open(mac_file):
    parts = line.split()
    if len(parts) >= 2:
        macs[parts[0]] = parts[1].upper()

fleet_known = {
    "192.168.1.1": "sharon (openwrt-primary)",
    "192.168.1.138": "jessicafletcher (appliance)",
    "192.168.1.139": "jessicafletcher (legacy DHCP lease)",
    "192.168.1.164": "tanyacheex (workstation)",
    "192.168.1.179": "markslone (gateway)",
    "192.168.1.186": "barryslone (NAS)",
    "192.168.1.250": "openwrt-secondary",
}

discovered = []
esp_targets = []
for ip in hosts:
    mac = macs.get(ip, "")
    oui = mac[:8] if len(mac) >= 8 else ""
    vendor = OUI.get(oui, "unknown")
    entry = {
        "ip": ip,
        "mac": mac or None,
        "vendor": vendor,
        "fleet_role": fleet_known.get(ip),
        "services": ports.get(ip, []),
    }
    discovered.append(entry)
    if "Espressif" in vendor:
        esp_targets.append({"ip": ip, "mac": mac, "staging": "ESPHome/OpenWrt candidate"})

payload = {
    "probe": "02_lan_iot_firmware_sweep",
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "node": os.environ.get("NEXO_NODE_NAME", "unknown"),
    "status": "ok" if hosts else "degraded",
    "data": {
        "subnet": os.environ.get("LAN_SUBNET", "192.168.1.0/24"),
        "hosts_up": discovered,
        "esp_firmware_staging_targets": esp_targets,
        "drift_alerts": [
            {"ip": e["ip"], "note": "legacy lease .139 active — DHCP reservation required"}
            for e in discovered if e["ip"] == "192.168.1.139"
        ],
    },
}
path = os.path.join(out_dir, "02_lan_iot_firmware_sweep_result.json")
with open(path, "w") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
print("[02] hosts_up=%d esp_targets=%d -> %s" % (len(discovered), len(esp_targets), path))
PYEOF
