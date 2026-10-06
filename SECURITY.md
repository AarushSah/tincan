# Security

tincan reads messages, contacts and call history, and sends texts as you, so a bug in it can expose private conversations or reach the wrong person. Please report such problems privately.

## Report a vulnerability

Use GitHub's private reporting: on the repository's **Security** tab, choose **Report a vulnerability** to open a private security advisory. Don't open a public issue or pull request, and don't describe the problem anywhere public until a fix is released.

Include:

- `tincan --version` and your macOS version
- The commands that show the problem, run on invented data such as the [fixture world](docs/development.md#run-tincan-on-invented-data)
- What an attacker, or a mistaken assistant, could do with it

Never include real messages, names, numbers, emails or ids, including your own. Replace them with invented ones such as Maya Chen and `+14155550142`.

## What counts

- **Privacy leaks.** Message content, contacts or call history shown where a command shouldn't show them, written to a file or log, or sent off the Mac; messages in Recently Deleted appearing anywhere.
- **Exclusion bypass.** Any way to read, search, stream or send to an excluded conversation or person.
- **Wrong-recipient sends.** A send that reaches someone other than the person and conversation tincan showed and you confirmed, or an ambiguous name or number resolved without asking.
- **Injection.** Text that runs as AppleScript, SQL or shell; terminal escape sequences from message content that reach the terminal; hidden characters that get past `send`.
- **Writes to Apple's data.** Anything that changes Messages' or call history's databases.

tincan holds no permissions of its own: it runs with those of the app that starts it. A bug that needs an attacker who already runs code as you, with the same permissions, is an ordinary bug: open an issue for it, without personal data.

## Supported versions

Fixes go into the latest release and `main`.
