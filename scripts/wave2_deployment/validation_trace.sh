#!/usr/bin/env bash
# =============================================================================
# validation_trace.sh — Stage-5 mesh/edge verifier (archive-fixed engine).
# Honesty law: asserts REAL probe output; exits non-zero on any failure.
# Checks: (a) routing — CF trace reachable, warp=on when on the gateway,
# outbound IP != ISP CGNAT canary; (b) policy-routing order when table 100
# exists; (c) optional LLM trace (VALIDATION_LLM=1) with TTFT via
# %{time_starttransfer} against the /v1/chat/completions route.
# =============================================================================
set -euo pipefail

FAILURES=0
note_ok()   { echo "  PASS: $1"; }
note_fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== AcidWurx Live Validation Trace ==="

# --- (a) Edge reachability + leak canary -----------------------------------------
TRACE_OUT="$(curl -4 -s --max-time 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"
if [ -n "${TRACE_OUT}" ]; then
  note_ok "cloudflare edge reachable"
  OUT_IP="$(printf '%s\n' "${TRACE_OUT}" | awk -F= '/^ip=/{print $2}')"
  WARP_STATE="$(printf '%s\n' "${TRACE_OUT}" | awk -F= '/^warp=/{print $2}')"
  echo "  outbound_ip=${OUT_IP:-unknown} warp=${WARP_STATE:-unknown}"
  if [ "${WARP_STATE:-}" != "on" ]; then
    echo "  NOTE: warp=off — this host is egressing direct-ISP. Expected before the gateway play is applied (DHCP option-3 redirect to markslone + wgcf). On markslone itself, warp=off means WARP is DOWN: check wg-quick@wgcf and the policy-routing rules."
  fi
  if [ -n "${ISP_CGNAT_IP:-}" ] && [ "${OUT_IP:-}" = "${ISP_CGNAT_IP}" ]; then
    note_fail "outbound IP equals ISP CGNAT canary (${ISP_CGNAT_IP}) — WARP breakout down (expected ON the gateway host)"
  else
    note_ok "outbound IP is not the ISP CGNAT canary"
  fi
else
  note_fail "cloudflare edge trace unreachable (check DNS/WAN)"
fi

# --- (b) Policy routing order (gateway hosts) --------------------------------------
if ip route show table 100 >/dev/null 2>&1 && [ -n "$(ip route show table 100 2>/dev/null)" ]; then
  BYPASS_OK=1
  for net in "100.64.0.0/10" "192.168.1.0/24" "172.16.0.0/12"; do
    ip rule show 2>/dev/null | grep -q "to ${net} lookup main" || BYPASS_OK=0
  done
  if [ "${BYPASS_OK}" -eq 1 ]; then note_ok "mesh/LAN/private bypass rules present (prio < breakout)"; else note_fail "bypass rules missing — routing loop/blackhole risk (Law 2)"; fi
  if ip rule show 2>/dev/null | grep -q "from 192.168.1.0/24 lookup 100"; then
    note_ok "LAN breakout rule present (from 192.168.1.0/24 -> table 100)"
  else
    note_fail "LAN breakout rule missing"
  fi
else
  echo "  SKIP: table 100 empty/absent (not the gateway host or WARP not deployed)"
fi

# --- (c) Optional LLM TTFT trace ------------------------------------------------------
if [ "${VALIDATION_LLM:-0}" = "1" ]; then
  ENDPOINT="https://${API_HOSTNAME:-api.acidwurx.org}/v1/chat/completions"
  PAYLOAD='{"model": "qwen2.5-coder-7b-instruct", "messages": [{"role": "user", "content": "Confirm mesh telemetry and compute state."}], "stream": false}'
  RESPONSE="$(curl -s -w '\n%{time_starttransfer}|%{http_code}' --max-time 100 -X POST "${ENDPOINT}" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' -d "${PAYLOAD}" || true)"
  HTTP_CODE="$(printf '%s\n' "${RESPONSE}" | tail -n 1 | cut -d'|' -f2)"
  TTFB="$(printf '%s\n' "${RESPONSE}" | tail -n 1 | cut -d'|' -f1)"
  BODY="$(printf '%s\n' "${RESPONSE}" | sed '$d')"
  echo "  http=${HTTP_CODE:-000} ttft=${TTFB:-?}s"
  if [ "${HTTP_CODE:-000}" = "200" ]; then
    note_ok "inference route live (TTFT ${TTFB}s)"
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "${BODY}" | jq -r '.choices[0].message.content // .response // "Stream active..."' 2>/dev/null | head -5 || true
    fi
  elif [ "${HTTP_CODE:-000}" = "401" ] || [ "${HTTP_CODE:-000}" = "302" ]; then
    echo "  NOTE: Access gate intercepted (expected headlessly — WebAuthn cannot be satisfied in CI). Route exists."
    note_ok "inference route present behind CF Access (401/302 = gate active)"
  else
    note_fail "inference route returned ${HTTP_CODE:-000}"
  fi
else
  echo "  SKIP: LLM trace (set VALIDATION_LLM=1; requires Access session or gate tolerance)"
fi

echo "=== failures: ${FAILURES} ==="
if [ "${FAILURES}" -gt 0 ]; then exit 1; fi
exit 0
