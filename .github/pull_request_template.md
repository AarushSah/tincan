## What and why

<!-- What changes for a person or an assistant using tincan, and why. -->

## How it was verified

- [ ] `./scripts/check.sh` passes
- [ ] Reading or decoding changed: `./scripts/check.sh --live` passes in a terminal with Full Disk Access
- [ ] Sending changed: sent to myself by hand (`tincan send me "…"`) in each typing mode touched
- [ ] Contacts changed: tried on a test card I created, then deleted it

## Checklist

- [ ] No real messages, names, numbers, emails or ids anywhere: code, tests, docs, commits or this description
- [ ] `--help`, `docs/`, `skills/tincan/SKILL.md` and `CHANGELOG.md` describe the new behavior
- [ ] Intended JSON changes re-recorded with `TINCAN_RECORD_SNAPSHOTS=1` and reviewed
- [ ] Conventional Commit messages
