# Send like a person

[← tincan](../README.md)

`tincan send` continues the conversation you already have, one bubble at a time, typed at your speed, and confirms each bubble in Messages before it reports it sent. After an SMS or RCS send, it checks briefly for a carrier refusing it.

```text
$ tincan send "Sam Park" "running 5 min late" "save me a seat 🙏" --dry-run
To Sam Park  ·  iMessage  ·  chat:10
  1  running 5 min late                                                      types 5.1s
  2  save me a seat 🙏                                                       waits 1.5s · types 4.9s
  About 11s · typing into Messages
Dry run: nothing was sent.
```

The dry run shows where the text goes and how long each bubble takes to type. Run the same command without `--dry-run` and tincan shows the plan, asks `Send 2 messages to Sam Park? [y/N]`, then types each bubble and reports its status.

## Write the bubbles

```sh
tincan send chat:4 "I'm in!"
tincan send me "test from tincan"
printf 'on my way\n\nsee you soon\n' | tincan send "Sam Park" - --yes
tincan send "Sam Park" "the plan" --file ~/Documents/itinerary.pdf
```

Each text argument is one bubble. `-` reads bubbles from standard input, separated by blank lines. A send takes at most 12 bubbles of at most 4,000 characters each. New lines and tabs are fine; other control characters, bidirectional embeddings, overrides and isolates (U+202A–U+202E, U+2066–U+2069), line and paragraph separators, and invisible characters that spell hidden text are refused with `invalid_input` (exit 64), because Messages would show the text differently from the preview. Those are tag characters outside England's, Scotland's and Wales's flags, and variation selectors carrying data: two or more in a row, or one after nothing or a space. One selector after a character, such as an emoji's U+FE0F, is fine, and so is a zero-width space, which spells nothing.

## Choose where it goes

| You name | tincan sends to |
| --- | --- |
| A person, by name or `contact:<id>` | Your most recent one-to-one conversation with them, on its service, as Messages would |
| A person whose conversations use several addresses | Nowhere yet: it lists them (`ambiguous_destination`, exit 3) |
| A number or email, or `address:<address>` | Your most recent conversation with that address, never another of the person's; with none, a new conversation there |
| A person you have never messaged | Their only phone number, or only email. With several, it lists them (`ambiguous_address`, exit 3). |
| `chat:<id>` | Exactly that conversation. A group's plan lists everyone in it. |
| A group's name | Nowhere yet: people in a group can rename it, so tincan asks for its `chat:<id>` (`ambiguous`, exit 3) |
| `me` | Your conversation with yourself, on any of your addresses; without one, a new conversation at your most-used address |

A person's iMessage and SMS conversations with one number count as one address. When you also text them at an email, tincan can't know which you mean:

```text
$ tincan send Maya "running 5 min late"
? You text Maya Chen at 2 addresses. Say which conversation:
    maya@example.com · iMessage   last message 6:26 AM    chat:3
    +1 (415) 555-0142 · SMS       last message yesterday  chat:2
    +1 (415) 555-0142 · iMessage  last message Mon        chat:1
  → Ask the person which conversation they mean, then send to its reference:
    `tincan send <reference> …`.
```

Send to the `chat:<id>` or address the person means; JSON's `route_reason` says why tincan chose a conversation. `--service imessage`, `sms` or `rcs` considers only conversations that use that service, as Messages lists them or as their recent messages went, and always wins.

### The service a conversation uses

Messages keeps a service for each conversation, and it can lag behind how the conversation actually goes: a conversation listed as RCS may have gone over iMessage for weeks, and sending over RCS then leaves as SMS. So without `--service`, tincan reads the conversation's 10 newest messages from the last 30 days, leaving out reactions, group events and messages that failed to send:

| Recent messages | tincan sends over | Says |
| --- | --- | --- |
| None | The service Messages lists | Nothing |
| All iMessage, at least one of them from the other person, in a conversation Messages lists as SMS or RCS | iMessage, in the same conversation | `route_reason` ends `over iMessage like its recent messages`; `service_switched` warning |
| The newest on another service than the send, otherwise | The service Messages lists, or the one `--service` asks for | `route_reason` ends `its recent messages went over …`; `service_differs` warning |

A message from the other person over iMessage shows their address receives iMessage; your own alone doesn't, so tincan never switches on those. A group keeps its service. A new conversation uses iMessage, marked `iMessage?` with a `service_unknown` warning, since tincan can't tell whether the address has it; if it fails, send again with `--service sms`.

tincan refuses a number your [region](people.md#numbers-without-a-country-code) can't complete (`incomplete_number`) and a recipient that is no name, reference, number or email, such as `@` (`invalid_input`). A number on other cards too gets a `shared_address` warning: whoever uses it reads the message. An [excluded](privacy.md#exclude-conversations) person is never messaged one-to-one (`excluded`).

## Confirm before sending

In a terminal, tincan shows the plan and asks. For a new conversation, the question names the address: `Start a new conversation with Maya Chen at +1 (415) 555-0142 and send 2 messages?`. `-y` or `--yes` skips the question.

Without a terminal, which covers `--json`, piped input and assistants, tincan can't ask. It sends only with `--yes` (else `confirmation_required`, exit 3), and starts a conversation only with `--new-conversation` too (else `new_conversation`, exit 3). These flags state that a person approved this exact text and recipient. `--dry-run` never needs them and never sends.

While `TINCAN_MESSAGES_DB`, `TINCAN_CALL_HISTORY_DB` or `TINCAN_CONTACTS_FILE` points tincan at test data, it checks everything and then refuses to send (`sending_unavailable`, exit 1). Dry runs work.

## Pace and the typing indicator

Each bubble takes as long to type as it would at `send.wpm`, 80 words per minute by default, with a human rhythm, between 0.8 and 30 seconds, and tincan pauses up to 3.5 seconds between bubbles. `--wpm` sets the speed for one send; the same `--seed` on the dry run and the send reproduces its timings.

| `--typing`, or `send.typing` | What the other person sees | Needs |
| --- | --- | --- |
| `auto` (default) | The typing indicator when tincan can type safely, otherwise paced delivery | Accessibility for the indicator |
| `keyboard` | The typing indicator. Refused in a group (`invalid_input`) or without Accessibility (exit 4); paces when a group could appear under the same title. | Accessibility |
| `paced` | Each bubble after its typing time, with no indicator | Nothing extra |
| `off` | Bubbles back to back, 0.4 seconds apart | Nothing extra |

In `auto`, tincan types into Messages only in a one-to-one conversation, when no group could appear in Messages under the same title, the app that runs tincan has Accessibility, the screen is unlocked, and you haven't used Messages in the last 30 seconds. Otherwise it paces, and `method_reason` says why, such as `groups are paced without the typing indicator`.

To type, tincan fills only Messages' message field, one character at a time, without key events or taking focus, after checking the conversation's title and that the field is empty; a draft of yours makes it pace. Before every character it checks again that the conversation is still shown and that the field holds only what it typed, so switching conversations or typing in Messages stops it without touching your text. It also stops when you start using Messages between bubbles. If anything goes wrong it clears what it typed, when the field is still its own, and paces the rest, and never sends a bubble twice.

## Check that it landed

tincan records the newest message in Messages' database before each bubble, then waits up to 12 seconds (24 for an attachment) for a newer outgoing message with the same text.

| Status | Meaning |
| --- | --- |
| `sent` | Messages finished sending it. It doesn't mean the recipient got it. |
| `delivered` | The recipient's device received it |
| `read` | The recipient read it; only with read receipts on |
| `failed` | Messages reported an error, or the carrier sent back a notice that it wasn't delivered |
| `unconfirmed` | Handed to Messages but not seen sent in time; it may still arrive |
| `skipped` | Not attempted, because an earlier bubble failed or wasn't confirmed |

A send stops at the first `failed` or `unconfirmed` bubble: half a conversation beats bubbles out of order or twice. It exits 0 when every bubble went, 2 when some did (`send_partial`) and 1 when none did: `send_unconfirmed` when Messages may still send what it hasn't confirmed, `send_failed` otherwise. An unconfirmed bubble is never reported as not sent; check the conversation before sending it again. Each confirmed bubble has its `ref`, and a send that fully went returns `next`, a `watch` command that waits for the reply.

`--wait delivered` or `--wait read` keeps checking for receipts for up to `--timeout` seconds (60 by default). iMessage and RCS report delivery; read times need the recipient's read receipts; SMS reports neither. Waiting never turns a sent bubble into a failure. Reading with tincan never sends a read receipt. JSON's `delivered` is `true` only when every bubble reached the recipient's device; before telling someone a message arrived, send with `--wait delivered` and check it.

### Carrier bounces

A carrier can refuse an SMS or RCS message after Messages has sent it, and text back a notice such as `Free Msg: Unable to send message - Message Blocking is active`. After an SMS or RCS send, tincan looks for one for `--bounce-wait` seconds, 10 by default (0 doesn't look, 60 at most), stopping early once every such bubble is delivered. JSON's `bounce_check_seconds` says how long it looked.

A notice counts when it arrives after the bubble, in its conversation or from the recipient's address, and its text contains `Unable to send message` or `Message Blocking is active`, or starts with `Free Msg:` and says the message couldn't be sent or delivered or was blocked, ignoring case. The match is narrow on purpose, since it turns a sent bubble into a failed one; a notice worded otherwise, or from a short code, isn't recognized, and finding none doesn't prove the message arrived.

Each bubble sent before a notice becomes `failed`, with `error_code: carrier_bounce` and the notice in `bounce` (`ref`, `text`, `at`), and the send fails with `carrier_bounce` (exit 1), or with `send_partial` (exit 2) when other bubbles went. If the recipient uses iMessage, send again with `--service imessage` once the person approves.

## Attach files

`--file` attaches one ordinary file of at most 100 MB, after the text, and can be repeated. tincan runs with Full Disk Access, which reaches far more than anyone means to share, and an assistant asking it to send can be misled. So tincan follows links and allows only places your own documents live:

| Allowed | Refused (`file_not_allowed`) |
| --- | --- |
| Your home folder, as macOS records it | `~/Library`, hidden files and folders in your home folder such as `~/.ssh`, and tincan's settings |
| `/Volumes` and `/tmp` | In them, `Library` folders and hidden files and folders, as in a backup of a home folder; the rest of `/private/var/folders`, and anything else such as `/etc` |
| Your temporary folder (`getconf DARWIN_USER_TEMP_DIR`) | Folders, devices, pipes and hard-linked files |

A larger file fails with `file_too_large`. To send a refused file, save a copy somewhere allowed, such as Documents. The preview and result show each file's full path and size. tincan copies each file to `~/Library/Messages/Attachments/tincan/`, where Messages reliably reads it, sends from that copy, and removes its copies after a day.

## When a send fails

Every error names its next step, and the [reference](reference.md#error-codes) lists them all. The ones that need care:

| Result | Next step |
| --- | --- |
| `ambiguous`, `ambiguous_destination`, `ambiguous_address`, `incomplete_number` (exit 3) | Ask the person which candidate they mean, or for the full number. Send to a group only by the `chat:<id>` they confirm. |
| `confirmation_required`, `new_conversation` (exit 3) | Get approval of the exact text and recipient, then add `--yes`, and `--new-conversation` once they confirm a new address |
| A bubble `failed` with `Messages refused the send: …` | Nothing went out. A new iMessage conversation may need `--service sms`. |
| A bubble `unconfirmed` | Read the conversation before anything else; never resend automatically. After `Messages did not respond within 45 seconds`, check that Messages is running. |
| `carrier_bounce` (exit 1), or bubbles with `error_code: carrier_bounce` | The carrier refused the message. Tell the person it wasn't delivered, and ask before sending again, over iMessage with `--service imessage` if they use it. |
| `automation_denied` (exit 4) | Turn on Messages under the app that runs tincan (the error names it) in System Settings → Privacy & Security → Automation. In a terminal, `tincan doctor --fix` walks through it. |

## Messages tincan sent

tincan records the GUID and time of each bubble it sends, once Messages has it, in `~/Library/Application Support/tincan/sent.jsonl`, readable only by you. It keeps no text and no recipient; those stay in Messages. Reading uses it to tell the messages tincan sent, such as an assistant's, from the ones you typed: in JSON they have `sent_by_tincan: true`, and formatted output marks each run of them `via tincan`.

Only sends from this Mac are known. A bubble Messages never confirmed has no GUID to record, and dry runs and declined sends send nothing.
