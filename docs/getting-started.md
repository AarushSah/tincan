# Install and set up

[← tincan](../README.md)

Use this guide to install tincan on a Mac, grant the permissions it needs to the app you run it from, and run your first commands. You need macOS 14 or later, Messages signed in on this Mac, and a Swift 6 toolchain (Xcode 16 or later, or its Command Line Tools). SMS and RCS appear when your iPhone forwards text messages to this Mac, and call history when it syncs calls.

## 1. Install the CLI

From this checkout:

```sh
./scripts/install.sh
export PATH="$HOME/.local/bin:$PATH"
tincan --version
```

The script builds tincan, signs it ad-hoc, and installs it as `~/.local/bin/tincan`, with a man page (`man tincan`) and zsh, bash and fish completions. It prints where each went and the line to add to your shell profile, if any. `PREFIX=/usr/local ./scripts/install.sh` installs under `/usr/local` instead. Run the script again after updating the checkout, and use the installed binary day to day.

You don't need a signing certificate: permissions don't depend on how tincan is signed, because macOS gives tincan the permissions of the app that runs it.

## 2. Grant permissions

```sh
tincan doctor --fix
```

Doctor opens the right list in System Settings for each missing permission, waits up to three minutes, and moves on as soon as it sees the grant. Press Return to skip a step.

| Permission | Why | What you do |
| --- | --- | --- |
| Full Disk Access | Messages and call history are protected files | System Settings opens at Full Disk Access and Finder shows your terminal app. Turn it on, or drag it into the list (or click + and choose it), then quit and reopen the terminal. |
| Contacts | Names for numbers, and contact changes | Click OK when macOS asks whether your terminal may access your contacts. If you denied it before, turn your terminal on in the Contacts list that opens. |
| Automation → Messages | Sending. Reading doesn't need it. | Click OK when macOS asks whether your terminal may control Messages. |
| Accessibility (optional) | The typing indicator. Sends are paced without it. | Answer `y`, then turn your terminal app on in the list that opens, or add it with +. |

Full Disk Access applies only after the terminal restarts, so press Return once it's on; at the end, doctor reminds you to quit and reopen the terminal.

The grants belong to the terminal you ran it in, not to tincan. An editor, an assistant's app or SSH needs its own; `tincan doctor` run there names the app, and [which app gets them](permissions.md#which-app-gets-them) lists each case. `--fix` needs a terminal; with `--json` or without one it exits 64 (`invalid_input`), and `tincan doctor --json` reports the same checks without changing anything.

## 3. Check the setup

```sh
tincan doctor
```

Doctor's first line, such as `Permissions come from Terminal`, names the app whose permissions tincan runs with (check `host`), and the permission checks are titled for it, such as `Full Disk Access for Terminal` and `Contacts for Terminal`. Each check that needs attention has a `→` suggestion. Doctor exits 0 when no check fails and 2 when one does. [What tincan needs](permissions.md#what-tincan-needs) explains each permission.

## 4. Try it

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

`tincan` on its own shows up to five unread conversations and up to five missed calls from the last seven days that you haven't returned. Then try:

```sh
tincan chats
tincan read Maya
tincan who Maya
tincan calls --missed --since 7d
tincan send me "hello from tincan" --dry-run
```

Replace Maya with someone you text. `send me` goes to your conversation with yourself, a harmless first send: remove `--dry-run`, and tincan shows the plan and asks first.

Formatted results go to standard output. Next steps such as `Earlier: tincan read Maya --before m:<id>` or `More with --limit 40.`, warnings and questions go to standard error, so a terminal shows everything while `tincan chats | grep Maya` gets only the result. `-j` is `--json` and `-y` is `--yes` wherever they exist, and `-n` is `--limit` in every listing: `tincan chats -n 5 -j`. For scripts, use [`--json`](assistants.md).

tincan also tells your terminal what it's doing, with the [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status) (OSC 7501), so a terminal that supports it can show this on a tab you aren't looking at. `send` reports how many of its messages Messages has confirmed, a question such as `Send 2 messages to Sam Park?` shows that tincan is waiting for you, and `doctor --fix` and `doctor --request contacts` show when they wait for System Settings or a question from macOS. `send` and `doctor` end by reporting what happened, such as `Sent 2 messages to Sam Park.` or why it failed, and answering no reports that tincan stopped. Reads report nothing, and the terminal clears what's left when tincan exits. Reports go to standard error when it is a terminal, never with `--json`, and not when `TERM` is `dumb`. Terminals without support ignore them.

A mistyped command names the one you probably meant, and a name of several words without quotes shows the quoted command:

```text
$ tincan chat
? "chat" isn't a tincan command. Did you mean chats?
  → Run `tincan chats`, or `tincan --help` for every command.
$ tincan who Sam Park
? "Sam Park" needs quotes to be one argument.
  → Run `tincan who 'Sam Park'`.
```

Continue with [messages](messages.md), [sending](sending.md) or [scripts and assistants](assistants.md).

## Change settings

```sh
tincan config
tincan config set send.wpm 55
tincan config set region GB
tincan config reset
```

| Key | Default | Meaning |
| --- | --- | --- |
| `region` | Your Mac's region | Country for numbers without a country code, such as `US` or `GB`; `""` returns to the Mac's |
| `send.wpm` | `80` | Typing speed, 5 to 250 words per minute |
| `send.typing` | `auto` | `auto`, `keyboard`, `paced` or `off`; see [typing modes](sending.md#pace-and-the-typing-indicator) |

Settings live in `~/.config/tincan/config.toml`; `tincan config path` prints where. With no file, as on a fresh install, tincan uses the defaults. The file is safe to edit by hand within the [subset of TOML tincan reads](reference.md#settings-file). A mistake in it is an error, not something tincan ignores: every command that reads Messages stops with `invalid_config` and names the line, so a typo can never quietly stop excluding a conversation.

`tincan config reset` restores the defaults and keeps your [exclusions](privacy.md#exclude-conversations); `config reset --all` clears them too, after asking.
