# tincan

tincan is a macOS command-line tool for Messages, Apple Contacts, and phone and FaceTime call history—for you and your AI assistants.

Read someone's conversations across iMessage, SMS and RCS, look up contacts and missed calls, and send messages one bubble at a time, paced like typing. Preview sends before anything goes out; ambiguous recipients stop the command.

Run `tincan` to see unread conversations and missed calls you haven't returned. This example uses fictional data:

```text
$ tincan
tincan  Wednesday, September 23, 2026

Unread  4 messages in 4 conversations
  ● Climbing crew 🧗   rope or bouldering?      chat:4
  ● +1 (415) 555-0199  Your code is 123456      chat:6
  ● Sam Rivera         secret plans for friday  chat:5
  ● Maya Chen          sent you the photos 📸   chat:3

Missed calls  last 7 days, not called or texted back
  ↙ Unknown caller     Missed                 40m ago
  ↙ +1 (415) 555-0122  Missed · not returned  8:20 AM
  ↙ Northwind Dental   Missed · not returned  7:20 AM

tincan read <name> · tincan send <name> "…" · tincan --help
```

## Install and try it

You need **macOS 14 or later**, **Swift 6** (Xcode 16 or later, or its Command Line Tools), and Messages signed in. SMS, RCS and call history require an iPhone on the same Apple Account, with text forwarding and call syncing enabled.

```sh
git clone https://github.com/AarushSah/tincan.git
cd tincan
./scripts/install.sh
export PATH="$HOME/.local/bin:$PATH"
```

Add the `export` line to your shell profile so it also applies in new terminals. Then set up permissions:

```sh
tincan doctor --fix
```

Grant permissions to the terminal app you run tincan from. After enabling Full Disk Access, **quit and reopen the terminal** before continuing. [Getting started](docs/getting-started.md) walks through each permission.

```sh
tincan doctor
tincan
tincan read Maya
tincan who Maya
tincan send me "hello from tincan" --dry-run
```

Replace Maya with someone you text. `read` combines their one-to-one conversations into a timeline; `who` shows their addresses, conversations and recent calls. `send me` previews a message to yourself. Remove `--dry-run` in a terminal to review the plan and confirm sending.

## For assistants

```sh
tincan skill
tincan read Maya --json
```

`tincan skill` prints the assistant guide for the installed version. With `--json`, commands return versioned JSON with stable references, pagination cursors and meaningful exit codes; `watch --json` streams JSON Lines. JSON mode never prompts.

The app running the assistant needs its own permissions. See [scripts and assistants](docs/assistants.md) for setup, exporting the skill and handling results.

## Safety

- **Reading is read-only.** Messages and call history databases are never written to, and messages are never marked as read.
- **Ambiguity stops the command.** Names come from Apple Contacts. For an ambiguous person or sending address, tincan lists candidates and exits 3 so you can choose explicitly.
- **Changes have previews.** `send`, `contacts add` and `contacts edit` support `--dry-run` and ask before acting in a terminal. With `--json` or without a terminal, they require explicit approval via `--yes`.
- **Sending checks each bubble.** tincan confirms that Messages recorded it as sent; delivery and read receipts are separate statuses. A failed or unconfirmed bubble stops the send.
- **Exclusions filter message content inside database queries.** Excluded conversations cannot be read, searched, watched or sent to. See [privacy and exclusions](docs/privacy.md).

tincan makes no network connections; Messages handles delivery. Output shared with an assistant is subject to that assistant's data handling.

## Guides

| Topic | Guides |
| --- | --- |
| Setup | [Getting started](docs/getting-started.md) · [Permissions](docs/permissions.md) |
| Conversations | [Reading, searching and following messages](docs/messages.md) · [Sending](docs/sending.md) |
| People | [Contacts and identity](docs/people.md) · [Call history](docs/calls.md) |
| Automation | [Scripts and assistants](docs/assistants.md) · [JSON and error reference](docs/reference.md) |
| Privacy | [Exclusions and local data](docs/privacy.md) · [Report a security issue](SECURITY.md) |
| Project | [Design](docs/design.md) · [Roadmap](docs/roadmap.md) · [Changelog](CHANGELOG.md) |
| Development | [Development guide](docs/development.md) · [Contributing](CONTRIBUTING.md) |

Run `tincan --help`, `tincan <command> --help` or `man tincan` for the full command reference.

## License

tincan is available under the [MIT License](LICENSE). It includes PhoneNumberKit and libphonenumber's metadata; see [third-party notices](THIRD_PARTY_NOTICES.md).
