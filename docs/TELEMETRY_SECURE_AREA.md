# TELEMETRY_SECURE_AREA.md — the "AI-readable, nobody-else-readable" design

## The access model (and its honest limits)

The chat AI (Qwen) **cannot hold credentials** — anything pasted into a chat
transcript must be treated as leaked (Law 9). So instead of sharing tokens,
the telemetry area uses **crypto, not ACLs**, exactly as the July archive
originally specified ("*encrypted within the repo using a key you set up so
that you [the AI] can read the full content*"):

| Layer | Visibility | Who reads it |
|---|---|---|
| `runs/<node>/<run>/INDEX.json` | plaintext metadata (statuses, sha256s, flags) | anyone — contains nothing sensitive |
| `runs/<node>/<run>/BRIEFING.md` | plaintext, **secret-scrubbed at source** (token-shaped strings become `sha256:16` fingerprints before leaving the host) | **the AI, directly, by URL** — this is the "allow access" surface |
| `runs/<node>/<run>/enc/raw.tar.gz.age` | ciphertext (age → sops → openssl backend chain, **fail-closed**) | only the fleet (private age key in `~/.config/nexo/age/keys.txt`) |
| `*.log`, full receipts | never leave the host (`local-only` class) | fleet only |

**Granting the AI access = telling it the public repo URL.** No secrets move.
If the telemetry repo is private instead, access = paste `./nexo.sh report`
output into the chat (same briefing, rendered locally).

## One-time setup (on jessicafletcher — gh is already authenticated there)

```bash
gh repo create acidwurx-nexus-telemetry --public
gh auth setup-git
cd ~/platform-2-homelab/acidwurx-nexus
./nexo.sh push --dry-run        # shows the classified plan, touches nothing
./nexo.sh push                  # first real push + flag issue
```

Create the label set once (repo → Issues → Labels): `telemetry`, `wave1`,
`telemetry-blindspots`, `telemetry-drift`, `telemetry-degraded`,
`telemetry-dns-violation`.

## The flag system ("flag which things I push, every time")

1. **`telemetry/PUSH_MANIFEST.json` is the law**: five classes
   (index/briefing = plaintext, raw = encrypted, receipts = metadata-only,
   logs = local-only). **Default-deny** — anything not matched never leaves
   the host. Edit the manifest to reclassify; pack.py enforces it.
2. **Every push computes flags** from content: `blindspots-found`,
   `drift-detected`, `dns-violation`, `degraded-probe` (+ manual `--flag X`).
3. **Every push creates a GitHub Issue** titled `telemetry: <node> <run>
   [flags]` with the briefing as body and flags mapped to **labels** — so
   "what did the fleet push, and what needs attention" is answerable from
   the repo's Issues page at a glance, filterable per label.
4. Command blocks from the AI are tagged `▶ PUSH:` (results go to the secure
   area) or `▶ LOCAL ONLY:` (never leaves the fleet) so the intent of every
   instruction is explicit before you run it.

## Routine

```bash
./nexo.sh wave1          # collect (read-only)
./nexo.sh report         # print the redacted briefing locally (review before push)
./nexo.sh push           # classify -> encrypt -> push -> flag issue
```

Decryption (fleet side only):
```bash
age -d -i ~/.config/nexo/age/keys.txt runs/<node>/<run>/enc/raw.tar.gz.age | tar xz
```

## Rotation & hygiene

- The age recipient is the repo's `.sops.yaml` key — stable across runs;
  rotate with `generate_nexus_engine.py --rotate-keys` and re-encrypt history
  if ever required.
- BRIEFING redaction is defense-in-depth, not the primary control: probes
  already emit fingerprints instead of secrets; redaction catches anything
  that slipped in (e.g. a token inside a captured env dump).
- The telemetry repo has NO credentials in it — compromising it yields
  metadata + ciphertext. Keep it that way: never push `.env`, keys, or
  `backups/` (gitignored in the ops repo; default-deny here).
