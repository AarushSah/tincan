# People and contacts

[← tincan](../README.md)

tincan connects the addresses Messages records to people through Apple Contacts, and when the address book can't settle who someone is, it says so instead of guessing.

```sh
tincan who Maya
tincan who +14155550177
tincan contacts Northwind
tincan contacts duplicates
tincan contacts edit Maya --nickname Mayo --dry-run
```

## Look up a person

```text
$ tincan who Maya
Maya Chen                                                                               contact:maya
Designer, Northwind · Birthday March 4, 1990

Reach them at
  +1 (415) 555-0142  mobile  iMessage · SMS
  maya@example.com   home    iMessage

Conversations
  chat:4  Climbing crew 🧗   iMessage · 6 messages · 55m ago · 1 unread
  chat:3  maya@example.com   iMessage · 1 message · 6:26 AM · 1 unread
  chat:2  +1 (415) 555-0142  SMS · 2 messages · yesterday
  chat:1  +1 (415) 555-0142  iMessage · 30 messages · Mon

Calls
  3 calls, 1 missed
  ↗ 10m 00s · FaceTime audio    10:20 AM
  ↗ 2m 00s                           Mon
  ↙ Missed · called back in 5m       Mon
```

`who` shows every address Messages uses for a person, every conversation with them, and their recent calls. It takes any [reference](reference.md#references):

| You ask about | `who` shows |
| --- | --- |
| A number with no card | The number, and `Not in your contacts` |
| A number on several cards | `On 2 contact cards:` with their names, and a `shared_address` warning |
| A card whose number another card has too | `Shares +1 (415) 555-0177 with Riley Lee`, with the same warning |
| A group's `chat:<id>` | The people in it |

## How identity works

A **person** is a contact card in Apple Contacts, or a bare address when no card has it. Their **addresses** are phone numbers and emails, each with **conversations** on iMessage, SMS or RCS. People also share group conversations. **Messages** carry text, attachments, replies and reactions; **calls** attach to the same addresses.

```text
person → addresses → conversations → messages
                   ↘ calls
```

Commands use the same [references](reference.md#references): a name such as `Maya`, `+14155550142`, `maya@example.com`, `contact:<id>`, `chat:<id>`, or `me`.

1. **Cards come from Apple Contacts**: the same unified cards the Contacts app shows.
2. **Addresses are normalized.** Phone numbers become E.164 (`+14155550142`), using your region when a number has no country code; emails ignore case; short codes of up to six digits stay as digits.
3. **An address matches a card when the normalized values are equal.** Failing that, a card saved without a country code matches on a national number of seven or more digits, marked `match: "national"`, less certain.
4. **A name appears only when exactly one card has the address.** A number on two cards, such as a family landline or duplicate cards, shows as the number, with every card it could be. Naming one of the cards finds it, but messages and calls on the number may be anyone's who uses it, and a `shared_address` warning says so.
5. **A person's conversations are the one-to-one conversations with any of their addresses**, on any service. Groups that include them are listed separately.

A match between an address and a card is a fact about your address book, not proof of who typed a message.

## Numbers without a country code

Numbers without a country code, in Contacts or on the command line, are read in your region: the `region` setting, or your Mac's region. Change it with `tincan config set region GB`. Outside North America, tincan reads them with Google's libphonenumber metadata, through PhoneNumberKit, which knows each region's prefixes and number lengths. Full-width digits and the invisible direction marks phones add around numbers are read as plain digits.

| Written | Region | Normalized |
| --- | --- | --- |
| `(415) 555-0142` | US | `+14155550142` |
| `020 7946 0000` | GB | `+442079460000` |
| `91234 56789` | IN | `+919123456789` |
| `001 1 415 555 0142` | KR | `+14155550142`, dialled through a carrier's international prefix |
| `+44 (0)20 7946 0000` | any | `+442079460000` |
| `262966` | any | `262966`, a short code: six digits or fewer, without the region's trunk prefix |
| `555-0142` or `090-1234-5678` | US | Incomplete: no area code, or a Japanese number without `+81` |
| `0142` | any | Too short |

An incomplete number never gains a country code, so it can't be mistaken for a full number elsewhere. Every command that takes a person refuses it with `incomplete_number` (exit 3) and lists the full numbers on your cards and in Messages that it could be, such as `+81 90 1234 5678` on 健二 佐藤's card for `090-1234-5678`.

## Name matching

A name is compared with every card's name, nickname and company, and every group's name, ignoring case, accents and character width. The best rank wins only when one match has it:

| Rank | Matches |
| --- | --- |
| 1 | The exact full name, with or without the middle name; a company card's name; a group's exact name |
| 2 | The exact nickname |
| 3 | The exact first name, last name or company |
| 4 | The start of any word in the name, nickname or company |
| 5 | Anywhere in the name, nickname, company or group name |

A one-word name treats ranks 1 to 3 alike, so `Alex` as one person's first name and another's nickname is ambiguous, while `Maya` finds Maya Chen even if you also know a Mayank. Cards with exactly the same addresses, such as Jordan and Riley Lee with only their home number, aren't ambiguous: `Lee` means that number, on neither card.

The people in a group choose its name, so a group never wins over a contact: when a group is among the best matches and the name matches any contact, the name is ambiguous. Groups under Unknown Senders or Junk, and excluded groups, never match by name, and `send` never picks a group by name.

## Find contacts

```sh
tincan contacts Northwind
tincan contacts find "+1 415 555 0142"
tincan contacts show Maya
```

`contacts` is short for `contacts find`. It searches names, nicknames and companies, or matches a number or email; seven or more digits without a country code also find numbers that end with them. Without a query it lists every card, 25 at a time.

`contacts show <person>` prints one card with its labelled numbers and emails. It and `contacts edit` take a name, number, email, `address:<address>`, `contact:<id>`, or `me` for the card with your addresses, and never pick between cards: several matches fail with `ambiguous`, and an address no card has with `not_found`.

## Duplicate and shared cards

```text
$ tincan contacts duplicates
Cards that share a number or email  1
  +1 (415) 555-0177  different names
    Jordan Lee  1 conversation, last yesterday  contact:jordan-lee
    Riley Lee   1 conversation, last yesterday  contact:riley-lee

tincan never merges cards. Merge duplicates in Contacts → Card → Look for Duplicates.
```

This lists cards that share an address, then cards with the same name. Two cards with one number can be duplicates or a shared line; two with one name can be one person or two. tincan shows each card's conversations to help you decide, and never recommends one. Merge in Contacts, or take a number off the wrong card with `tincan contacts edit contact:<id> --remove-phone <number>`.

## Add and edit contacts

```sh
tincan contacts add --name "Lina Ortiz" --phone mobile:+14155550133 --email lina@example.com --dry-run
tincan contacts edit Maya --add-phone work:+14155550199 --dry-run
tincan contacts edit Maya --remove-phone +14155550142 --add-phone work:+14155550142 --dry-run
tincan contacts edit contact:maya --birthday 03-04
```

Changes go through Apple Contacts and sync like any other edit. In a terminal, `add` and `edit` show the change and ask; without one, or with `--json`, they need `--yes` (`confirmation_required`). Preview with `--dry-run`.

| Rule | Detail |
| --- | --- |
| Names | `--name` takes a full name and uses its last word as the family name; `--first` and `--last` set them exactly. A card with only `--org` is a company card. |
| Labels | `mobile:`, `home:`, `work:`, `iphone:`, `main:`, `school:`, `other:` or your own, before a colon. Unlabelled numbers are `mobile`, emails `home`. |
| Birthday | `YYYY-MM-DD`, or `MM-DD` without a year. It must exist: `02-29` needs a leap year or no year. |
| Duplicates | `add` refuses an address another card has (`duplicate_contact`, exit 3); `--allow-duplicate` adds it anyway once you're sure. A card with the same name only warns `same_name_exists`. |
| Edits | Only the fields you pass change; `--nickname ""` clears one. `--remove-phone` removes the number however it's formatted, and only with the same extension, if any. Removals apply before additions, so removing and adding an address relabels it. Adding an address the card has, or one twice, is `invalid_input`. |
| Conversations | Removing an address that conversations use warns `address_in_use`, listing them: they lose this card's name. |

Before saving an edit, tincan writes a vCard of the card as it was to `~/Library/Application Support/tincan/backups/`, readable only by you, and names it in the result. If the backup can't be written, the card isn't changed. To undo, edit the card back or import the `.vcf` into Contacts.
