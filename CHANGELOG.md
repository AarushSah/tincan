# Changelog

Notable changes to tincan. Versions match `tincan --version`, set in `Support/Info.plist`.

## 0.1.0 - Unreleased

First version.

### Reading

- `chats`, `read`, `who`, `search` and `calls` read Messages, call history and Apple Contacts on this Mac, read-only, and never mark anything as read. They keep reading while Messages has removed its database's `-wal` file, checking again before each read until it returns.
- `read` merges a person's iMessage, SMS and RCS one-to-one threads into one timeline; `chat:<id>` reads one thread or a group. Bodies stored only in `attributedBody` are decoded, reactions are folded onto the messages they react to, and replies carry `reply_to_ref` and a short `reply_to_preview` of the message they quote.
- Every message has a `ref` (`m:<id>`); options that take a message also accept the bare number or its GUID. `read` pages backward with `--before`, forward with `--after` and around a message with `--around`, and `earlier` and `later` give the command for each direction. `chats`, `read`, `search` and `calls` report `has_more` and a `next.command` that keeps their filters and limit.
- Conversations name their `current_service`, and `read` also lists the services of the messages on the page.
- `search` reads text straight from each message's stored bytes and decodes only matches. It ignores case and accents, and matches curly and straight quotes, dashes and hyphens, and … and three dots alike.
- `calls` shows direction, outcome, kind, talk time, junk and location, and for missed calls whether you called or texted back. `tincan` on its own shows unread conversations and missed calls from the last seven days you haven't returned.
- Messages in Recently Deleted never appear. Conversations Messages filed under Unknown Senders or Junk stay out of listings unless you pass `--all`, and are marked `filtered` when shown.
- Messages whose text hides characters Messages doesn't show carry `hidden_text`: tag characters outside England's, Scotland's and Wales's flags, variation selectors carrying data, and zero-width characters. When they spell text, `hidden_text.decoded` has it, a `hidden_text` warning names the messages, and formatted output shows `⟨hidden: …⟩` in their place.
- Your messages that tincan sent carry `sent_by_tincan`, and formatted output marks each run of them `via tincan`, from tincan's send ledger.

### Following new messages

- `inbox` shows the newest unread messages. `inbox --after <cursor>` reads everything since a cursor, with nothing missed or repeated.
- `watch` streams new messages and reactions in the order Messages recorded them, as JSON Lines with `--json`, with cursors that are always safe to resume from. `--batch` groups a conversation's messages by when they were sent, and `--in <person>` follows their conversations, including ones that start while watching.
- A cursor past the newest message, as after Messages rebuilds its database, continues from the latest message with a `cursor_ahead` warning.

### People and identity

- Phone numbers are normalized to E.164 in a configurable region. Numbers without a country code outside North America are read with Google's libphonenumber metadata, through PhoneNumberKit, which knows each region's prefixes and lengths; short codes stay digits. Full-width digits and invisible direction marks are read as plain digits.
- A name appears only when exactly one card has the address. A number on several cards names nobody: it lists `possible_contacts` and warns `shared_address`. A card saved without a country code matches on its national number, marked `match: "national"`.
- A number without its country code that the region can't complete is refused with `incomplete_number`, listing the full numbers it could be.
- `me` names you wherever a person is expected, by your own addresses in Messages.
- An ambiguous name, number or group stops with exit 3 and lists every candidate. A one-word name matches a full name, nickname, first or last name alike, in every command. Hints never name a candidate, and mention `--yes` and similar flags only as a step after the person confirms.

### Sending

- `send` continues the conversation you already have, one bubble at a time at your typing speed (80 words per minute by default), and shows the typing indicator through Accessibility when it can. `route_reason` and `method_reason` explain its choices. The typing indicator only ever fills Messages' message field, checking before every character that the conversation and field are still its own, and the text is sent through AppleScript to the planned conversation.
- A number or email decides the conversation; a group is sent to only by its `chat:<id>`. A conversation Messages lists as SMS or RCS whose recent messages went over iMessage continues over iMessage, warning `service_switched`, and a send never falls back to another service than the one planned. `--service` always wins.
- Every bubble is confirmed in Messages' database, in the conversation it went to, before the next one goes. A send that doesn't fully go returns `ok: false` with every bubble's status: `send_failed`, `send_partial`, or `send_unconfirmed` when Messages may still send what it hasn't confirmed. After an SMS or RCS send, tincan looks for a carrier's notice that it wasn't delivered (`carrier_bounce`).
- `delivered: true` only when every bubble reached the recipient's device; `--wait` waits for delivered or read receipts.
- Without a terminal, sending needs `--yes`, and `--new-conversation` for an address you have never messaged. Dry runs say when a send would start a new conversation and list a group's members. Excluded people are never messaged.
- A bubble with a control character other than a new line or tab, a bidirectional override, a line or paragraph separator, or invisible characters that spell hidden text is refused with `invalid_input`.
- `--file` attaches one ordinary file of at most 100 MB from the home folder, `/Volumes`, `/tmp` or your temporary folder, never from a `Library` folder, a hidden file or folder, or tincan's settings in any of them.
- A send ledger records the GUID and time of each bubble tincan sent, with no text or recipient, so reading can mark them.

### Contacts

- `contacts find`, `show`, `add` and `edit`, with a vCard backup before every edit. Without a terminal, `add` and `edit` need `--yes`.
- `add` refuses a number or email that already has a card unless you pass `--allow-duplicate`. `edit` warns when a number or email it removes is used by conversations, or one it adds is on other cards, and removes a number only with the same extension. Removing and adding a number in one command relabels it.
- `contacts duplicates` lists cards that share a number, email or name, with their conversations, and never merges them.

### Privacy and exclusions

- `exclude` keeps conversations and people out of tincan, filtered inside every database query, including messages Messages filed in no conversation. Excluding a person also covers one-to-one conversations on their addresses that start later. `exclude remove` asks first, and needs `--yes` without a terminal.
- The settings file is a documented subset of TOML. A mistake, an unknown setting, or construct outside the subset stops commands with `invalid_config` naming the line, and settings that `TINCAN_CONFIG` or `XDG_CONFIG_HOME` point at must exist and keep the exclusions in `~/.config/tincan/config.toml` while tincan reads this Mac's Messages, so neither a typo nor another file can let a conversation back in.
- Formatted output removes escape sequences, control characters and bidirectional overrides from everything it prints, and tincan's own styles can't be forged by message text.

### Output and assistants

- `--json` on every command, with a versioned envelope, stable error codes with a message and hint, `truncated` warnings when a list stops at `--limit`, and exit codes: 1 failure, 2 partial, 3 needs the person's decision, 4 permission, 64 usage.
- `tincan skill` prints the assistant guide for the installed version, with topics for the details; `tincan skill --export <folder>` writes it as a skill folder.
- `-n` is `--limit`, `-y` is `--yes` and `-j` is `--json` in every command that takes them.
- Formatted output ends with the command that continues it, on standard error, so standard output stays the result.

### Permissions and install

- tincan runs with the macOS permissions of the app that starts it, like other command-line tools. `doctor` names that app and checks the four permissions for it, with steps to grant each; `doctor --fix` walks through them in a terminal, and `doctor --request contacts` asks macOS for Contacts access for an assistant once the person agrees.
- `scripts/install.sh` builds tincan, signs it ad-hoc (or with a certificate named by `TINCAN_SIGNING_IDENTITY`) with the hardened runtime, and installs it with a man page and zsh, bash and fish completions.
- `scripts/release.sh` builds a signed, notarized universal binary with its man page, completions, license and third-party notices. `packaging/homebrew/tincan.rb` is a Homebrew formula template, and `packaging/github-actions/` holds inactive CI and release workflows.

### Development

- `TINCAN_MESSAGES_DB`, `TINCAN_CALL_HISTORY_DB`, `TINCAN_CONTACTS_FILE` and `TINCAN_CONFIG` run tincan on invented data, with sending off. `TINCAN_EXPORT_WORLD` exports the fixture world the tests use.
- `scripts/check.sh` checks formatting, builds in the Swift 6 language mode and runs the tests, which compare JSON shapes against snapshots; `--live` adds read-only checks against this Mac's Messages that print counts only.
