# Contributing to tincan

tincan works on people's messages, contacts and call history, so every change has to keep it read-only by default, exact about identity and honest about what it couldn't confirm. Read [AGENTS.md](AGENTS.md) for the project's rules and [development](docs/development.md) for how the code fits together.

## Never use real personal data

Nothing real goes into the repository, an issue or a pull request: no messages, names, numbers, emails, contact ids or chat ids, in tests, fixtures, docs, examples, commit messages, logs or screenshots. Use invented people such as Maya Chen and Sam Park, numbers in the 555-01xx range such as `+14155550142`, `example.com` emails and small chat ids such as `chat:42`.

Output of `chats`, `read`, `who`, `inbox`, `search`, `watch`, `calls`, `contacts` or `doctor` on your own Mac contains personal data. To show output, run tincan on the fixture world instead:

```sh
TINCAN_EXPORT_WORLD=/tmp/tincan-world swift test --filter WorldExport
. /tmp/tincan-world/env.sh && tincan chats
```

## Build and test

You need macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later).

```sh
swift build
./scripts/check.sh
./scripts/install.sh --debug
```

`./scripts/check.sh` builds tincan and runs every test that doesn't need your Mac's data. It must pass before every commit, and CI runs the same checks on every pull request and push to `main`. It checks formatting first; `--no-lint` skips that while you iterate. After a change to reading or decoding, run `./scripts/check.sh --live` from a terminal app that has Full Disk Access (restart it after granting); the live checks print counts only.

Tests never send messages or change contacts. Verify a sending change by hand with `tincan send me "…"`, and a contact change on a card you created for the test. When a JSON result changes on purpose, re-record its snapshot with `TINCAN_RECORD_SNAPSHOTS=1 swift test --filter TincanCLITests` and review the diff.

## Style and commits

- Follow `.swift-format`: run `swift format --in-place` on the files you change. `./scripts/check.sh` must report no findings.
- Update the command's `--help`, its guide in `docs/`, [docs/reference.md](docs/reference.md) for a new field, warning or error code, the assistant skill in `skills/tincan/` when assistants need to act differently, and `CHANGELOG.md` for anything a person would notice.
- Use [Conventional Commits](https://www.conventionalcommits.org/) such as `feat:`, `fix:` and `docs:`, and keep each commit focused, with its code, tests and documentation together.

## Security and privacy problems

Report a way to leak data, get around an exclusion, send to the wrong person or inject commands privately, as [SECURITY.md](SECURITY.md) describes. Don't open a public issue.
