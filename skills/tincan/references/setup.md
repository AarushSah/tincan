# Setup

Permissions, settings, and keeping this guide installed for an assistant.

## Permissions

tincan runs with the macOS permissions of the app that runs you, not with its own.
Only the person can grant them, in System Settings. You can't change privacy settings: never run `tccutil`,
and don't work around a missing permission.

| Sign | Missing | Effect |
| --- | --- | --- |
| `full_disk_access_required` (exit 4), or `setup_needed: true` from `tincan -j` | Full Disk Access | Nothing in Messages or call history can be read |
| `contacts_access_required` (exit 4), or a `contacts_unavailable` warning | Contacts | People show as numbers; contact commands fail |
| `automation_denied` (exit 4) | Automation for Messages | Sending fails |
| `accessibility_required` (exit 4) | Accessibility | No typing indicator; `--typing keyboard` fails |

1. Run `tincan doctor -j`. `data.host.name` names the app or program whose permissions tincan uses: the one that runs you.
   Each check has `id`, `status` (`ok`, `warn`, `fail`, `skip`), `title`, `detail` and `fix`. It exits 2 when a check fails.
2. Pass each failing check's `title` and `fix` on to the person. The `fix` says what to turn on for that app.
   For Contacts not yet allowed, follow Ask for Contacts below.
3. You can't run `tincan doctor --fix`: it needs a terminal, and grants whichever app the person runs it in.
4. Full Disk Access applies after the person restarts that app, or at least starts a new session. Then run the command again.

- Checks: `host`, `data_sources`, `full_disk_access`, `contacts`, `automation`, `accessibility`,
  `account`, `config`. A `host` warning means tincan couldn't tell which app runs it.
- `data.host.kind` is `app`, `program`, `ssh` or `unknown`. `program` is a program launchd started, such as a background
  service that runs you: grant that program, at `data.host.path`, not the app it is part of.
- In the Claude desktop app, commands run under Claude Code (`com.anthropic.claude-code`), so Claude Code needs them, not Claude.
- Some apps, such as Claude Code, Visual Studio Code and Cursor, don't say why they would use Contacts.
  macOS may refuse them Contacts without asking; names then appear as numbers.

### Ask for Contacts

When the `contacts` check's `fix` names `tincan doctor --request contacts`, macOS hasn't asked the app yet.
The person can't turn Contacts on until it has, so:

1. Ask the person whether `data.host.name` may use their contacts. Never run the request without a yes.
2. Tell them macOS will ask on the Mac's screen, then run `tincan doctor --request contacts -j`. It waits for their answer.
3. The `contacts` check reports it: `ok` when allowed. If they declined, pass on its `fix`; macOS asks only once.

- `tincan doctor --request contacts --dry-run -j` says whether it would ask.
  It never asks after a refusal, or for an app that can't ask.

## Settings

- `tincan config -j` shows the settings: `region`, `send_wpm`, `send_typing`, and exclusion counts.
- `tincan config set region GB`, `tincan config set send.wpm 55`, `tincan config set send.typing paced`.
  Change settings only when the person asks.
- `region` is the country for numbers written without a country code.
- `tincan config reset` restores defaults and keeps exclusions. `--all` also clears exclusions: only when asked.

## Setup errors

| Code | Exit | Do |
| --- | --- | --- |
| `invalid_config` | 1 | The settings file has a mistake. Show the person the message. |
| `config_missing` | 1 | `TINCAN_CONFIG` or `XDG_CONFIG_HOME` points at missing settings. Show the person the message. |
| `config_drops_exclusions` | 1 | Those settings leave out the person's exclusions. Show the person the message. |
| `messages_missing` | 1 | This Mac has no Messages database. The person opens Messages and signs in. |
| `call_history_missing` | 1 | No call history on this Mac. Calls sync from an iPhone with the same Apple Account. |
| `sending_unavailable` | 1 | `TINCAN_MESSAGES_DB`, `TINCAN_CALL_HISTORY_DB` or `TINCAN_CONTACTS_FILE` points tincan at other data. Nothing was sent. |
| `database_error`, `automation_unavailable`, `error` | 1 | An internal step failed. Read `message`; `tincan doctor -j` may say more. |

- Never create or point at another settings file to get past `invalid_config`, `config_missing` or `config_drops_exclusions`.
  The settings hold the person's exclusions.

## Install this guide

`tincan skill` prints this guide for the installed version, and `tincan skill <topic>` each topic.
For an assistant that loads skills from a folder, export them:

1. Preview: `tincan skill --export ~/.claude/skills/tincan --dry-run -j`.
2. Write: `tincan skill --export ~/.claude/skills/tincan -j`. It creates `SKILL.md` and `references/`.
3. After updating tincan, export again. Files that differ are replaced only with `--yes` (`-y`),
   after the person approves, since they may have edited them (`confirmation_required`, exit 3).

- `data.files` lists each file's `path` and `status`: `created`, `replaced` or `unchanged`.
- `tincan skill --list -j` lists the topics with a summary and file each.
