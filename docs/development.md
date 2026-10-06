# Develop tincan

[← tincan](../README.md)

Read [AGENTS.md](../AGENTS.md) for the project's rules and [design and rationale](design.md) before changing tincan. It works on real people's messages: keep it read-only by default, exact about identity, and explicit about what it couldn't confirm.

```sh
swift build
./scripts/check.sh
./scripts/install.sh --debug
```

## Build and install

You need macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later, or its Command Line Tools). `swift build` checks that everything compiles. `scripts/install.sh` signs tincan ad-hoc and replaces `~/.local/bin/tincan` atomically, with the man page and completions; `--debug` builds faster. `TINCAN_SIGNING_IDENTITY` signs with a certificate in your keychain instead, named by its name, the start of it such as `Developer ID Application`, or its SHA-1; a launchd job that runs tincan directly keeps its permissions across rebuilds only with one. It signs every build with the hardened runtime and refuses to install one without it. Preview the man page with `swift package generate-manual`.

tincan runs with the permissions of the app that starts it, so a build under `.build/` gets the same ones as the installed binary when both run in the same terminal. Grant permissions to your terminal or assistant's app, never to a tincan binary; see [permissions](permissions.md).

The linker embeds `Support/Info.plist`, every file of the assistant skill in [skills/tincan/](../skills/tincan/) (`SKILL.md` and `references/`), which `tincan skill` prints, and `Support/PhoneNumberMetadata.json`, PhoneNumberKit's copy of libphonenumber's metadata, so an installed tincan needs no resource bundle beside it. After updating PhoneNumberKit in `Package.swift`, copy its `Sources/PhoneNumberKit/Resources/PhoneNumberMetadata.json` over that file; a test fails until you do. A plain `swift build` doesn't relink when only an embedded file changes; `check.sh`, `install.sh` and `release.sh` relink for you. Adding a skill topic means adding its file under `skills/tincan/references/`, its name to `skillTopics` in `Package.swift`, and its name to `BundledSkill.topics` in `Sources/TincanCLI/Commands/Skill.swift`. `Info.plist` gives tincan its name, identifier and version; macOS shows its purpose strings only when tincan is its own responsible process, as when a launchd job runs it directly.

## Test

```sh
./scripts/check.sh
./scripts/check.sh --no-lint
./scripts/check.sh --live
```

`scripts/check.sh` checks [formatting](#format) first, then builds tincan and runs `swift test --skip Live`, and fails on any finding or failure. Run it before every commit; there is no CI yet, so it is the gate (inactive drafts wait in [packaging/github-actions/](../packaging/github-actions/)). `--no-lint` skips the formatting check while you iterate. `--live` adds read-only checks against this Mac's Messages and call history that print only counts; run it from a terminal with Full Disk Access after any change to reading or decoding, and after a macOS update.

The tests never touch this Mac's real data. `Tests/TincanKitTests` tests the model against fixtures built from invented people. `Tests/TincanCLITests` runs the real `tincan` binary (or the one `TINCAN_TEST_BINARY` names) against a fixture world, with no terminal, and checks formatted output, exit codes and JSON.

| Fixture | Builds |
| --- | --- |
| `MessagesFixture`, `CallHistoryFixture` | A temporary `chat.db` or `CallHistory.storedata` with Apple's schema and rows shaped like Apple's. `MessagesFixture` can leave out columns to cover older macOS. |
| `Schemas` | Apple's `CREATE TABLE` and `CREATE INDEX` statements from a current Mac; no messages |
| `AttributedBodyFixture` | `attributedBody` blobs archived as Messages writes them |
| `InMemoryContactsProvider`, `SampleContacts` | An address book in memory |
| `FakeMessagesApp` | Stands in for Messages in sending tests, writing the rows Messages would. Nothing is sent. |
| `World` | The CLI tests' world: invented messages, calls, contacts and settings, with a number on two cards, two people named Sam and senders not in Contacts |

The fixtures live in [Tests/TincanKitTests/Support/](../Tests/TincanKitTests/Support/), with copies in [Tests/TincanCLITests/Support/](../Tests/TincanCLITests/Support/), because test targets can't import each other; keep them in step.

### Run tincan on invented data

Export the CLI tests' world and source its settings in the same shell command:

```sh
TINCAN_EXPORT_WORLD=/tmp/tincan-world swift test --filter WorldExport
. /tmp/tincan-world/env.sh && tincan chats
```

`env.sh` sets four variables:

| Variable | Replaces |
| --- | --- |
| `TINCAN_MESSAGES_DB` | `~/Library/Messages/chat.db` |
| `TINCAN_CALL_HISTORY_DB` | The call history database |
| `TINCAN_CONTACTS_FILE` | Apple Contacts, with a JSON array of cards shaped like `tincan contacts --json`. `contacts add` and `edit` rewrite the file, with backups beside it. `{"authorization": "denied", "contacts": [...]}` simulates denied access, and `{"authorization": "not_determined", "answer_to_request": "authorized", "contacts": [...]}` the answer when tincan asks, as `doctor --request contacts` does. |
| `TINCAN_CONFIG` | The settings file, which must exist |

While any of the first three is set, `send` refuses with `sending_unavailable` and doctor warns `Reading other data`; dry runs work. Use this world, never your own Mac, for examples in docs and issues.

### JSON shapes

The CLI tests compare each JSON result's shape, every key path with its type, with snapshots in [Tests/TincanCLITests/Snapshots/](../Tests/TincanCLITests/Snapshots/). After an intended change, re-record them and review the diff:

```sh
TINCAN_RECORD_SNAPSHOTS=1 swift test --filter TincanCLITests
```

### Sending and contacts

Sending and contact changes have no automated live tests. Verify a sending change by hand in a terminal with `tincan send me "…"`, in each typing mode you touched; tincan asks to start the conversation if you have never messaged yourself. Verify contact changes on a card you created for the test, and delete it afterwards.

## Format

`.swift-format` holds the code style for the toolchain's `swift format`: 4-space indentation, lines up to 160 columns, and swift-format's defaults otherwise.

```sh
./scripts/lint.sh
./scripts/lint.sh Sources/TincanKit/Config
```

`scripts/lint.sh` lints `Sources`, `Tests` and `Package.swift`, or the paths you give. It fails on any finding; `swift format --in-place --recursive <path>` fixes most of them. `.swift-format` keeps a function's return type on its signature line.

## Release

Nothing has been published yet. `scripts/release.sh` builds a universal binary, signs it with a Developer ID Application certificate, notarizes it when `TINCAN_NOTARY_PROFILE` names a `notarytool` profile, and packages `dist/tincan-<version>-macos.tar.gz`.

```sh
./scripts/release.sh --dry-run
./scripts/release.sh --unsigned
TINCAN_NOTARY_PROFILE=<profile> ./scripts/release.sh
```

`--unsigned` makes an ad-hoc signed archive to test packaging, never to publish. To release, set the version in `Support/Info.plist`, date its [changelog](../CHANGELOG.md) section, tag `v<version>`, and attach the archive and its `.sha256` to a GitHub release. The draft [release workflow](../packaging/github-actions/release.yml) and [Homebrew formula](../packaging/homebrew/tincan.rb) take over once the repository is public.

## Find the code

| Area | Source |
| --- | --- |
| Entry point | [Sources/tincan/](../Sources/tincan/) |
| Commands and the home screen | [Tincan.swift](../Sources/TincanCLI/Tincan.swift), [Sources/TincanCLI/Commands/](../Sources/TincanCLI/Commands/) |
| JSON envelope, errors and exit codes | [Output.swift](../Sources/TincanCLI/Support/Output.swift), [Payloads.swift](../Sources/TincanCLI/Support/Payloads.swift), [TincanError.swift](../Sources/TincanCLI/Support/TincanError.swift) |
| Planners' refusals and warnings, and how commands report them | [PlanIssue.swift](../Sources/TincanKit/Planning/PlanIssue.swift), [Planning.swift](../Sources/TincanCLI/Support/Planning.swift) |
| Test data sources | [DataSources.swift](../Sources/TincanCLI/Support/DataSources.swift), [FileContactsProvider.swift](../Sources/TincanCLI/Support/FileContactsProvider.swift) |
| Formatted output | [Sources/TincanCLI/Rendering/](../Sources/TincanCLI/Rendering/) |
| Addresses, phone numbers, contacts directory, references | [Sources/TincanKit/Identity/](../Sources/TincanKit/Identity/) |
| Messages database and body decoding | [Sources/TincanKit/Messages/](../Sources/TincanKit/Messages/), [Sources/TincanObjC/](../Sources/TincanObjC/), which catches Objective-C exceptions from Apple's unarchiver |
| Call history, Contacts and planning `contacts add` and `edit`, settings | [Calls/](../Sources/TincanKit/Calls/), [Contacts/](../Sources/TincanKit/Contacts/), [Config.swift](../Sources/TincanKit/Config/Config.swift) |
| Planning a send, pacing, AppleScript, keyboard, confirmation, ledger | [Sources/TincanKit/Sending/](../Sources/TincanKit/Sending/) |
| Permissions and the app that holds them | [Permissions.swift](../Sources/TincanKit/System/Permissions.swift), [PermissionHost.swift](../Sources/TincanKit/System/PermissionHost.swift), [PermissionAdvice.swift](../Sources/TincanCLI/Support/PermissionAdvice.swift), [Doctor.swift](../Sources/TincanCLI/Commands/Doctor.swift) |
| Install, checks and releases | [scripts/](../scripts/), [Support/](../Support/), [packaging/](../packaging/) |

## Conventions

Beyond the rules in [AGENTS.md](../AGENTS.md):

- **Check optional columns.** Apple adds columns in most releases; use the column checks in `MessagesDatabase` and `CallHistoryDatabase` rather than assuming a schema.
- **Standard output carries only the result.** Progress, questions, warnings and next steps (`Output.hint`, such as `Earlier: …`) go to standard error.
- **Confirm before claiming.** A send is `sent` only after it appears in the database.

## Keep the documentation truthful

The README says why tincan exists, shows a first success and routes by task. Each guide in `docs/` owns its workflow, [reference](reference.md) owns every field, warning and error code, and `--help` owns every flag. When behavior changes, update the command's help, its guide, the reference, and the skill if assistants need to act differently; add a line to the [changelog](../CHANGELOG.md). Take example output from the fixture world, and put unimplemented ideas only in the [roadmap](roadmap.md).
