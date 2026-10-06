# Privacy and exclusions

[← tincan](../README.md)

tincan works on some of the most private data on a Mac, so it reads only what a command asks for, writes very little, keeps everything on the Mac, and lets you keep conversations out of it entirely.

```sh
tincan exclude add "Sam Park"
tincan exclude list
tincan exclude remove "Sam Park"
```

## What stays on the Mac

tincan makes no network connections: no accounts, telemetry or update checks. Messages delivers what you send, exactly as if you had typed it.

When an assistant runs tincan, the output goes to that assistant, and if its model runs in the cloud, to its provider. tincan can't change that, so keep what an assistant sees small: exclude what it should never see, and ask for narrow results with `--limit`, `--since` and cursors.

## What tincan reads and writes

| What | Where | How |
| --- | --- | --- |
| Messages | `~/Library/Messages/chat.db` | Read-only. Never written, never marked as read. Attachments are reported, never opened. Like any SQLite reader, opening it can create `chat.db-shm`, SQLite's shared index, when its `-wal` file exists without one. |
| Call history | `~/Library/Application Support/CallHistoryDB/` | Read-only |
| Contacts | Apple Contacts, through Contacts.framework | Read on demand; changed only by `contacts add` and `edit` |
| The Messages window | Accessibility, during a typed send | Only the conversation title and the message field |
| Files you attach | The path given to `send --file` | Only that file, from [allowed places](sending.md#attach-files) |
| Settings and exclusions | `~/.config/tincan/config.toml` | Written by `config` and `exclude`; mode 0600 |
| Send ledger | `~/Library/Application Support/tincan/sent.jsonl` | The GUID and time of each bubble tincan sent, so reading can mark them; no text or recipient; mode 0600 |
| Contact backups | `~/Library/Application Support/tincan/backups/` | A vCard before each `contacts edit`; mode 0600 |
| Attachment copies | `~/Library/Messages/Attachments/tincan/` | Staged for Messages, removed after a day |

Reading commands write nothing. Messages you deleted are filtered out with excluded conversations, inside the database queries, while they wait in Recently Deleted.

## What tincan prints

Message text, group names, file names and even contact names can come from other people. Formatted output keeps only their printable text: it removes escape sequences, control characters and the invisible characters that reorder text, so nothing someone sends can clear the screen, write to your clipboard, disguise a link or rewrite a line. Tag characters and variation selectors that spell hidden text show as a dimmed `⟨hidden: …⟩`. tincan's own colors are marked with a random value on each run, so text can't imitate them.

`--json` gives every value exactly as stored. A program that prints JSON values to a terminal should clean them the same way.

## Exclude conversations

```text
$ tincan exclude add "Sam Park"
✓ Excluded Sam Park  chat:10
✓ Excluded Sam Park  every one-to-one conversation at +1 (415) 555-0188
! Sam Park is in 2 group conversations that stay readable: Climbing crew 🧗 (chat:4) and Sam, 健二
  and 2 others (chat:9). Exclude a group with `tincan exclude add chat:<id>` only if the person
  asks.
```

An excluded conversation is filtered inside every database query, before any message is decoded, so it is never read, searched, streamed, summarized or sent to, by you or an assistant. Naming its `chat:<id>` fails with `excluded` (exit 3), and a group's name no longer matches it. Messages that Messages filed in no conversation, as older macOS releases sometimes left them, are left out too when they are from or to anyone in an excluded conversation, or from no one tincan can tell.

| `exclude add` takes | Excludes |
| --- | --- |
| `chat:<id>` or a group's name | That conversation |
| A person | Every one-to-one conversation with them, on every service, and all their addresses, so a conversation that starts later on one of them is excluded too. Their groups stay readable (`groups_not_excluded`). Run it again if they start using an address their card doesn't have. |
| `address:<address>` | Only the one-to-one conversations on that address, now and later |

Once a person or one of their addresses is excluded, tincan never messages them one-to-one. `read`, `who`, `chats --with`, `search` and `watch` say when some of a person's conversations are left out (`excluded_conversations`), so an empty answer isn't mistaken for silence. `chats` still lists an excluded conversation, last, without its message or time. Exclusions cover messages only: calls and contact cards still show.

## Lift an exclusion

`exclude list` shows each excluded conversation and address. `exclude remove` takes a `chat:<id>` or `address:<address>` from that list, or a person to lift all of theirs; removing a one-to-one conversation lifts its address too. A number on several cards is one exclusion, so lifting it through one card lifts it for all, with a `shared_address` warning.

Only you lift an exclusion. In a terminal, `exclude remove` and `config reset --all` say what tincan could read again and ask first; without a terminal they need `--yes` (`confirmation_required`), which an assistant adds only after you ask.

Exclusions are stored in the settings file by each conversation's Messages GUID and each address, so they survive Messages rebuilding its database. A mistake in the file, including a misspelled or unknown setting, stops every command that reads Messages with `invalid_config`, a settings file that isn't where `TINCAN_CONFIG` or `XDG_CONFIG_HOME` points stops them with `config_missing`, and one there that leaves out exclusions in `~/.config/tincan/config.toml` stops them with `config_drops_exclusions`, so neither a typo nor another settings file can quietly let a conversation back in. An `address:` entry that is no number or email excludes nothing, and `exclude list` says so. `tincan config reset` keeps exclusions; `config reset --all` clears them.

## Remove tincan's data

```sh
rm ~/Library/Application\ Support/tincan/sent.jsonl
rm -r ~/Library/Application\ Support/tincan/backups
rm -r ~/.config/tincan
```

tincan starts a new ledger and backups when needed; without the ledger, messages it sent before look like ones you typed. Deleting the settings file also removes your exclusions. tincan holds no permissions of its own: to withdraw its access, turn off the app you run it from in each list under System Settings → Privacy & Security, which also withdraws it from everything else that app runs.
