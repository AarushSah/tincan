# tincan

This repository owns tincan, a Swift CLI for reading and sending Messages, reading call history, and managing Apple Contacts on a Mac, for people and their assistants. Keep it read-only by default, exact about identity, and honest about what it could not confirm.

- Never put real personal data in the repository: no real messages, names, numbers, emails, contact ids or chat ids in tests, fixtures, docs, examples, commit messages or logs. Use invented people such as Maya Chen and Sam Park, numbers such as `+14155550142` (the 555-01xx range), `example.com` emails and small chat ids such as `chat:42`.
- Don't paste output of `chats`, `read`, `who`, `inbox`, `search`, `watch`, `calls`, `contacts` or `doctor` from a real Mac into issues, docs or chat; it contains personal data. Read code, use `--help`, or run tincan on the fixture world: `TINCAN_EXPORT_WORLD=<dir> swift test --filter WorldExport`, then `. <dir>/env.sh && tincan …` in the same shell command.
- Tests never send messages or change contacts. Verify sending by hand in a terminal with `tincan send me "…"` (it asks to start the conversation if you have never messaged yourself), and contact changes on a card you created for the test.
- Never write to Messages' or call history's databases. Read through the read-only SQLite wrapper; change data only through Messages (AppleScript, Accessibility) or Contacts.framework.
- Apply exclusions in SQL. Every query that returns message content goes through `MessagesDatabase.fetchMessages` or adds `exclusionCondition`, which also removes messages in Recently Deleted.
- Never resolve ambiguity by guessing. Identity code returns every candidate; commands report them with exit 3. Hints use placeholders such as `<reference>`, never a candidate, and never offer a safety flag such as `--yes` as the next step.
- Nothing prompts without an interactive terminal or with `--json`. Any command with an effect outside tincan supports `--dry-run` and needs an explicit flag when there is no one to ask.
- Report failures through `TincanError` with a stable code, a hint and the right exit status (1 failure, 2 partial, 3 needs input, 4 permission, 64 usage). Print through `Output` so human and JSON results stay the same data.
- CLI help, `docs/`, `skills/tincan/SKILL.md` and the README must describe implemented behavior. Proposed features belong in `docs/roadmap.md`, not as placeholder commands. Record user-visible changes in `CHANGELOG.md`.
- Keep the README focused on purpose, first use and navigation. Put workflows in their owning guide, and use `--help` for exhaustive flags.
- Verify every change with `./scripts/check.sh` before committing: it builds and runs `swift test --skip Live`, and fails on any failure. After changes to reading or decoding, run `./scripts/check.sh --live` from a terminal with Full Disk Access; the live checks print counts only.
- JSON results are a contract. CLI tests compare their shapes with `Tests/TincanCLITests/Snapshots`; after an intended change, re-record with `TINCAN_RECORD_SNAPSHOTS=1 swift test --filter TincanCLITests` and review the diff.
- Refresh the installed CLI with `./scripts/install.sh` (add `--debug` for speed). tincan runs with the permissions of the app that starts it; grant them to your terminal or assistant's app, never to a tincan binary.
- Use Conventional Commits (`feat:`, `fix:`, `docs:`). Keep commits focused, with the relevant code, tests and documentation. Push only when asked.
