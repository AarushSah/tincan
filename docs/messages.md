# Read and follow conversations

[← tincan](../README.md)

tincan reads Messages' database on this Mac, read-only: it decodes every message body, folds reactions onto their messages, names each sender from Apple Contacts, and never marks anything as read.

```sh
tincan chats
tincan read Maya
tincan inbox
tincan search dinner
tincan watch
```

Messages in Recently Deleted and [excluded](privacy.md#exclude-conversations) conversations stay out of every command.

## Page through conversations

`chats --limit 20` shows the first page. Its `More:` hint gives the command for the next page, with the same filters and limit, using `--before chat:<id>`. JSON callers can follow `next.command` while `has_more` is true. The list reflects current activity, so a new message can move a conversation between pages.

## Name a person or conversation

Every command takes a name, number, email, `contact:<id>`, `chat:<id>` or `me`; the [reference](reference.md#references) lists every form. Copy `chat:<id>` and `contact:<id>` from any listing. When a name could mean more than one person or group, tincan lists them and exits 3 instead of picking one:

```text
$ tincan read Sam
? "Sam" could mean 2 people. Say which one:
    Sam Park    +1 (415) 555-0188              contact:sam-park
    Sam Rivera  +1 (628) 555-0131 · Northwind  contact:sam-rivera
  → Ask the person which one they mean, then use its reference: `tincan read <reference>`.
```

Repeat the command with the reference you meant, or a fuller name; [name matching](people.md#name-matching) explains the ranking.

## List conversations

```text
$ tincan chats --with Maya
● Climbing crew 🧗 (4)  Sam: rope or bouldering?                                     55m ago  chat:4
● Maya Chen             sent you the photos 📸                   maya@example.com    6:26 AM  chat:3
  Maya Chen             You: no worries                   SMS · +1 (415) 555-0142  yesterday  chat:2
  Maya Chen             You: did this one go through?           +1 (415) 555-0142        Mon  chat:1
```

`chats` lists conversations newest first, 20 by default; `--limit` (`-n`) changes that, and a cut-off list ends with `More with --limit 40.` `●` marks unread messages, groups show their size, SMS and RCS are labelled, and several conversations with one person each show their address. `--unread` shows only unread conversations, `--with <person>` a person's one-to-one and group conversations, and `--all` adds those Messages filed under Unknown Senders or Junk, marked `junk`. An excluded conversation is listed last, as `excluded`, without its message or time.

## Read a conversation

```text
$ tincan read chat:1 --after m:20 --limit 6
Maya Chen  ·  Current: iMessage                                           chat:1
────────────────────────────────────────────────────────────────────────────────
Earlier: tincan read chat:1 --before m:21 --limit 6

                              Monday, September 21

                                                        see you at 7:45 (edited)

↪ Maya: are we still on for dinner?
Perfect, booked it

                              You unsent a message

📎 IMG_0042.jpeg · 2.1 MB · not downloaded
📎 climb.mov · 48 MB · not downloaded

                                                        https://example.com/menu

Later: tincan read chat:1 --after m:26 --limit 6
```

`read Maya` merges your one-to-one conversations with her on iMessage, SMS and RCS into one timeline; `read chat:<id>` reads exactly one conversation, and is how you read a group. Your messages are on the right, and under your latest one tincan shows whether it was delivered or read. The [reference](reference.md#messages) shows how each kind of message appears. Reply messages carry a parent reference and, in JSON, a `reply_to_preview` with up to 160 characters of the parent's text when it is readable. Exclusions and Recently Deleted apply to previews too.

The header's `Current:` service describes the thread; `Shown:` appears when the messages on this page used different services. JSON distinguishes `conversation.current_services` from `conversation.message_services`, and each message keeps its own `service`.

For `read`, `search` and `calls`, JSON also reports `has_more` and a runnable `next.command`. `read` also has `earlier` and `later`, the commands for older and newer messages, whichever way you read.

| Option | Reads |
| --- | --- |
| `-n`, `--limit <n>` | The newest `n` messages in the range; 40 by default |
| `--since <time>` | Messages after a [time](reference.md#times), such as `yesterday` or `2h` |
| `--before <m:id or time>` | Older messages; `Earlier:` gives the exact command |
| `--after <m:id>` | The messages after one, oldest first; `Later:` gives the exact command |
| `--around <m:id>` | A message in context, such as a search result |
| `--ids` | Each message's `m:<id>` |

`--after` and `--around` take only a message, don't combine with `--before` or `--since`, or with each other. A message given to `--before`, `--after` or `--around` must be in the conversation you read. One from elsewhere fails with `unknown_message` and names its conversation; so does a reaction, naming the message it reacts to. When the number is on several cards, the header says `shared by Jordan Lee and Riley Lee` and a `shared_address` warning names them.

## See what's new

```sh
tincan inbox
tincan inbox --since 2h
tincan inbox --after m:55
```

`inbox` shows unread messages from other people, grouped by conversation, most recently active first. With `--since <time>` or `--after <cursor>` it shows every new message instead, with reactions. `--mine` adds your own messages, `--all` adds Unknown Senders and Junk, and `--limit` defaults to 200.

Every result ends with a cursor, as in `Later: tincan inbox --after m:55`: a position in Messages' history. Running that command later returns exactly what arrived since, nothing missed or repeated. When more is waiting, the output ends with `More waiting:` and the command to continue. A cursor newer than every message, as after restoring the Mac, continues from the latest one with a `cursor_ahead` warning; use `--since` to catch up by time.

## Search

```text
$ tincan search dinner
Maya Chen  are we still on for dinner?
           Mon · chat:1 · m:1
```

Search matches message text newest first, 20 by default, ignoring case and accents and treating curly and straight quotes, dashes and hyphens, and `…` and three dots alike. It doesn't search reactions or the names of people and groups; use `tincan who` or `tincan chats --with` for those.

| Option | Finds |
| --- | --- |
| `--in <person or chat>` | Only that conversation, or a person's one-to-one and group conversations |
| `--from <person>` | Only that sender, or `me` |
| `--since <time>`, `--before <time or m:id>` | A time range; `--before` with the oldest match's `m:<id>` continues the list |
| `--all` | Also Unknown Senders and Junk, otherwise searched only when `--in` or `--from` names them |

To see a match in context, read around it: `tincan read chat:1 --around m:1`.

## Watch new messages

```sh
tincan watch
tincan watch --in Maya --mine
tincan watch --from "Sam Park" --after m:55
```

`watch` prints each new message and reaction as Messages records it, until you press Ctrl-C. It checks about once a second and picks up new conversations and senders as they appear.

| Option | Effect |
| --- | --- |
| `--in <person or chat>` | Only that conversation, or a person's conversations, including ones that start while watching |
| `--from <person>` | Only messages and reactions from that person, or `me` |
| `--mine` | Also your own messages. Not with `--from <person>`; use `--in <person> --mine` for both sides. |
| `--after <cursor>` | Start after a cursor instead of now |
| `--all` | Also Unknown Senders and Junk |
| `--interval <seconds>` | Time between checks; 1 by default, from 0.2 to 3600 |

With `--json`, `watch` prints one JSON object per line, each with a cursor to resume from, and `--batch <seconds>` groups a burst of messages into one event; see [stream with watch](assistants.md#stream-with-watch).
