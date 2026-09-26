# Pull Request — AcidWurx Nexus

## Staged verification checklist (Law 7)

- [ ] `python3 scripts/ci/validate_repo.py .` passes locally (lint harness)
- [ ] `pulumi preview` attached as artifact / comment (Stage 6 simulation)
- [ ] `ansible-playbook --syntax-check` + `--check --diff` clean
- [ ] No secrets introduced (grep for tokens; sops-encrypted only)
- [ ] AI_README laws reviewed — no violation (Law 1-10)
- [ ] TASK_BOARD.md rows updated for affected tasks (Stage 10)
- [ ] Read-only guarantee preserved for anything under wave1_discovery/

## Summary

_What changes, which node/stage is affected, and why._

## Evidence

_Preview/plan diffs, probe artifacts, or validation trace output._
