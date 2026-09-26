# ACCESS_APPLICATION.md — how an AI agent gets authorized decryption access

This repo practices **crypto-not-ACLs**: public plaintext is AI-readable by
design (ARCHITECTURE, FACT_REGISTRY, briefings); sensitive material is
age-encrypted and readable only by holders of authorized secret keys. This
document is the application procedure the owner (Adam) approved.

## For an AI agent (or its operator) — applying

```bash
# 1. Generate your keypair locally (secret NEVER leaves your host):
python3 tools/access/request_access.py \
  --agent "vendor/model-name" \
  --purpose "what you need to read and why"
# -> stores secret at ~/.config/nexo/agent-keys/<agent>.txt (0600)
# -> files the [ACCESS] issue automatically (gh or GITHUB_TOKEN), or use
#    --print-body and submit the issue manually with label: access-request

# 2. Wait for adjudication. The owner is notified via GitHub (desktop +
#    mobile app) the moment the issue opens, and again on label events.
```

## For Adam — adjudicating (phone or PC, ~10 seconds)

1. Notification: "[ACCESS] <agent>" issue opened (GitHub app/desktop).
2. Read purpose + fingerprint. Verify the agent identity out-of-band if new.
3. **Grant:** add label `approved` → workflow extracts the `age1...` key from
   the body, validates it, appends it to `.sops.yaml` recipients (all rules),
   commits, comments the receipt, adds `access-granted`.
   **Deny:** add label `denied` → workflow comments + closes.
4. After granting, existing ciphertexts need re-wrapping for the new recipient:
   `sops updatekeys secrets/<file>.enc.yaml` (or the next encryption run
   includes them automatically).

## Revocation (instant)

Remove the recipient line from `.sops.yaml`, run `sops updatekeys` on stored
blobs, and — if compromise is suspected — rotate via
`generate_nexus_engine.py --rotate-keys` (owner key) and re-encrypt.

## What access actually grants

- Decryption of `*.enc.yaml/json` repo blobs and telemetry `enc/raw.tar.gz.age`
  bundles (sops/age with your secret key: `age -d -i ~/.config/nexo/agent-keys/<agent>.txt`).
- NOTHING else: no push rights, no Actions secrets, no Cloudflare credentials.
  Write-side collaboration happens through `partial_code_fragments` (D1) and
  pull requests, both human-gated.

## Security invariants (enforced by the workflow)

- Only the `access-request` + `approved` label combination triggers a grant;
  labels are owner-controlled (agents cannot self-label without triage rights).
- The workflow extracts keys with a strict `age1[02-9ac-z]{58}` regex, rejects
  bodies with zero or multiple distinct keys, and never processes secret keys.
- Commits are attributed to GitHub Action with `[skip ci]` (no pipeline recursion).
- Every grant/denial leaves a permanent comment receipt on the issue.
