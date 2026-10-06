# Permissions

[← tincan](../README.md)

macOS protects Messages, call history and Contacts with privacy permissions. Like any command-line tool, tincan runs with the permissions of the app that starts it: your terminal, your editor, or the app that runs an assistant. A program that launchd starts, such as an assistant's background service, holds its own. Grant them to that app or program. `tincan doctor` names it and checks each permission, and in a terminal `tincan doctor --fix` walks you through the missing ones.

## What tincan needs

| Permission | Doctor check | Used for | Without it |
| --- | --- | --- | --- |
| Full Disk Access | `full_disk_access` | Reading Messages (`~/Library/Messages/chat.db`) and call history | Nothing can be read (`full_disk_access_required`, exit 4) |
| Contacts | `contacts` | Names for numbers; `contacts add` and `edit` | People appear as numbers, with a `contacts_unavailable` warning. Contact commands fail with `contacts_access_required`, exit 4. |
| Automation → Messages | `automation` | Asking Messages to send | `send` fails with `automation_denied`, exit 4 |
| Accessibility | `accessibility` | Typing into Messages for the typing indicator (optional) | Sends are paced without the indicator. `--typing keyboard` fails with `accessibility_required`, exit 4. |

Reading never needs Automation or Accessibility.

## Which app gets them

macOS checks a command-line tool's *responsible process*, normally the app that started it. Doctor's first check (`host`) names that app, and `doctor --json` reports it as `host` with `kind` (`app`, `program`, `ssh` or `unknown`), `name`, `bundle_id` and `path`. Messages from tincan and macOS's own questions name it too. `program` is a program launchd started that isn't an app; its name and identifier come from the Info.plist linked into it, or else its file name.

| Where tincan runs | Who needs the permissions |
| --- | --- |
| A terminal, such as Terminal, iTerm2 or Ghostty | That terminal app, for everything run in it, including tmux sessions started from it |
| An editor's terminal or tasks | The editor |
| An assistant | The app that runs the assistant's commands: its desktop app, or the terminal you started it in. Some desktop apps run commands through a separate helper app; doctor names it and says where it is. |
| SSH | Remote Login. Full Disk Access is the switch Allow full disk access for remote users; other permissions go to `sshd-keygen-wrapper`. |
| A program launchd starts, such as an assistant's background service | That program, at the path doctor prints, even inside an app: the app's own grants do nothing for it. It can ask for Contacts only if the Info.plist linked into it says why (`NSContactsUsageDescription`). |
| A launchd job that runs tincan directly | tincan itself, its own responsible process: add the installed binary, such as `~/.local/bin/tincan`, with +. Doctor names tincan as the host. |

Each app needs its own grants. Full Disk Access for Terminal does nothing when an assistant's app runs tincan, and the reverse.

For example, the Claude desktop app runs commands through a helper app, Claude Code, at `~/Library/Application Support/Claude/claude-code/<version>/claude.app` (`com.anthropic.claude-code`), so Claude Code needs the permissions, not Claude. The + button's file picker hides `~/Library`: press ⌘⇧G and paste the path doctor prints.

## Granting them

Run `tincan doctor --fix` in a terminal. It opens each list in System Settings, shows the app in Finder so you can drag it in, and asks macOS for Contacts and Automation, whose questions name the app. It grants the terminal you run it in. With `--json` or without a terminal it refuses with `invalid_input` (exit 64): an assistant can't complete it, so it passes on the `fix` steps from `tincan doctor --json` to the person, and for Contacts can ask macOS once you agree.

By hand, in System Settings → Privacy & Security:

- **Full Disk Access.** Turn the app on, or add it with +. Then quit and reopen the app: macOS applies Full Disk Access when an app starts. For an assistant, restart its app, or at least start a new session; for a program launchd starts, restart the program.
- **Contacts.** The list has no + button: an app appears once it has asked. macOS asks the first time tincan reads contacts in a terminal, during `doctor --fix`, or when you or an assistant run `tincan doctor --request contacts`. An app that doesn't say why it would use Contacts, such as Claude Code, Visual Studio Code or Cursor, may be refused without a question and never appear in the list. Doctor says when that is likely, and names then appear as numbers when tincan runs from that app. See [ask for Contacts without a terminal](#ask-for-contacts-without-a-terminal).
- **Automation.** macOS asks whether the app may control Messages the first time tincan sends, or during `doctor --fix`. If it was declined, turn on Messages under the app in Automation.
- **Accessibility**, optional. Turn the app on, or add it with +.

Over SSH, turn on System Settings → General → Sharing → Remote Login ⓘ → Allow full disk access for remote users, then start a new SSH session. macOS usually can't ask an SSH session for Contacts, so names may be missing there.

### Ask for Contacts without a terminal

`tincan doctor --request contacts` asks macOS for Contacts access for the app or program that runs tincan, with `--json` and without a terminal, so an assistant can start it. It is never implied by another option. An assistant should ask you first, then run it and tell you to look at the Mac. macOS shows its question on the Mac's screen, tincan waits for your answer, and the Contacts check reports it.

It asks only when macOS hasn't asked that app yet and the app can ask. When access is allowed, it changes nothing. After a refusal it doesn't ask again, since macOS asks each app once; the check says where to turn it on. For an app that doesn't say why it would use Contacts, or over SSH, it doesn't ask and the check says so. `--dry-run` says whether it would ask.

## After updates

macOS ties each grant to the app's signature. When an app updates or is replaced, a grant can stop working while its switch still shows on. Turn the entry off and on again, then restart the app. If that doesn't help, remove it with − and add it again.

Updating tincan doesn't touch these grants, since they belong to the app that runs it. The exception is a launchd job that runs tincan directly: an ad-hoc signed build is a new program to macOS each time, so install with a certificate from your keychain, such as `TINCAN_SIGNING_IDENTITY="Apple Development" ./scripts/install.sh`, to keep its grants across updates.

## Security

A permission belongs to the whole app. Full Disk Access for a terminal lets every program you run in it read your messages, mail and files, and an assistant whose app has it can read them without tincan. tincan's exclusions and send checks limit what tincan does, not what the app can do; see [privacy](privacy.md).

To keep that access narrow, use a separate terminal app only for tincan or for your assistant, and grant only that app. Profiles or windows within one app share its permissions.

## Troubleshooting

Start with `tincan doctor`. With `--json`, `host` says which app's permissions tincan used and `executable` which binary ran.

| Symptom | Next step |
| --- | --- |
| `full_disk_access_required` although the switch is on | Quit and reopen the app doctor names. Check that it is the app you granted: an assistant may run commands through a helper app. Turn the entry off and on again. |
| Works in Terminal, fails from an assistant | Each app needs its own grants. Run `tincan doctor --json` from the assistant and grant the app in `host`. |
| Granted the assistant's app, but its background service still fails | launchd starts the service, so it holds its own grants (`kind: program`). Grant the program at the path doctor prints, then restart it. |
| Doctor warns `Permissions come from the app that runs tincan` | tincan couldn't tell which app runs it. Grant the terminal, editor or assistant app you started it from; macOS names it when it asks. |
| No Contacts question appears | macOS asks each app only once. If the app is in the Contacts list, turn it on. If it isn't, it may not be able to ask; see doctor's Contacts line. Without a terminal, `tincan doctor --request contacts` asks. |
| `automation_denied` | Turn on Messages under the app in System Settings → Privacy & Security → Automation, or run `tincan doctor --fix` in that app. |
| The Sending check shows `–` | Messages isn't running, so macOS can't answer yet. Open Messages, or run `tincan doctor --fix`. While `TINCAN_MESSAGES_DB`, `TINCAN_CALL_HISTORY_DB` or `TINCAN_CONTACTS_FILE` is set, sending is off and the check is always skipped. |
| No typing indicator | Check the Typing indicator line in doctor. In `auto` mode, tincan also paces in groups, while the screen is locked, while you are using Messages, and when a group could appear under the person's name or number; the send result's `method_reason` says why. |
| `messages_missing` | This Mac has no Messages database. Open Messages and sign in once. |
| `call_history_missing` | Turn on iCloud and Continuity for the same Apple Account on your iPhone and this Mac. |
