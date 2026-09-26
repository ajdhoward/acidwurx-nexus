#!/usr/bin/env bash
# =============================================================================
# notify.sh — optional push notification (ntfy.sh) for run milestones.
# Zero-config: silently skips when NEXO_NTFY_TOPIC is unset.
# Phone: install the ntfy app, subscribe to your topic. PC: ntfy.sh/<topic>.
# Usage: notify.sh "<title>" "<message>" [priority 1-5] [tags csv]
# =============================================================================
set -euo pipefail

TITLE="${1:-acidwurx-nexo}"
MESSAGE="${2:-}"
PRIORITY="${3:-3}"
TAGS="${4:-}"

if [ -z "${NEXO_NTFY_TOPIC:-}" ]; then
  echo "[notify] skipped (NEXO_NTFY_TOPIC unset)"
  exit 0
fi

python3 - "${NEXO_NTFY_TOPIC}" "${TITLE}" "${MESSAGE}" "${PRIORITY}" "${TAGS}" <<'PYEOF'
import sys, urllib.request
topic, title, message, priority, tags = sys.argv[1:6]
url = "https://ntfy.sh/" + topic
req = urllib.request.Request(url, data=message.encode("utf-8"), method="POST")
req.add_header("Title", title)
req.add_header("Priority", priority)
if tags:
    req.add_header("Tags", tags)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print("[notify] sent (http %d) to ntfy.sh/%s" % (resp.status, topic))
except Exception as exc:
    print("[notify] send failed (non-fatal): %r" % (exc,))
PYEOF
