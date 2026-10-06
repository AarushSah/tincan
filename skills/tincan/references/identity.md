# Identity

How to name people and conversations, and what to do when tincan can't tell who someone is.
Never guess. A wrong name on a message is worse than no name.

## References

| Write | Means |
| --- | --- |
| A name | A contact card or a group, by name, nickname or company |
| A phone number, in any format | That number; without a country code, read in the person's region |
| An email | That address |
| `contact:<id>` | That card |
| `chat:<id>` | That conversation, one-to-one or group |
| `address:<address>` | That number or email, as `tincan exclude list` shows it |
| `me` | The person: their own addresses. In `contacts show` and `contacts edit`, their own card. |
| `m:<id>` | A message: each message's `ref`. The bare number works too. |

- Copy `chat:`, `contact:` and `m:` references from results; don't construct them.
- Contact references are stable on this Mac but differ on the person's other devices.
- A name for several words needs quotes: `tincan who "Sam Park" -j`.

## Candidates (exit 3)

`ambiguous`, `ambiguous_destination`, `ambiguous_address` and `incomplete_number` stop and list `candidates`.

1. Show the person each candidate's `name` and `detail`. Never pick one, not even the first.
2. Ask which one they mean.
3. Run the same command again with that candidate's `reference`.

| Field | Meaning |
| --- | --- |
| `reference` | What to pass back once the person has chosen |
| `name`, `detail` | Short lines for the person |
| `addresses` | Every number and email; for a group, everyone's |
| `organization` | The card's company |
| `conversations`, `last_activity` | How many conversations include them, and the latest message; excluded ones left out |
| `excluded_conversations` | How many one-to-one conversations with them are excluded |
| `shares_address_with` | Other cards with one of these addresses: `contact`, `name`, `address`, `chats` |

- Hints use placeholders such as `<reference>`. Never fill one in yourself.
- `ambiguous_destination` (send): the person's conversations use several addresses; each candidate is a conversation.
- `ambiguous_address` (send): no conversation yet and several addresses; each candidate is an address.
- A group's name in `send` always stops with `ambiguous`, even with one candidate. Confirm the group first.
- A group never outranks a contact, and groups under Unknown Senders or Junk never match by name.

## Incomplete numbers

`incomplete_number` means a phone number the region can't complete, in any command that takes a person:

- A number without its country code, such as `090-1234-5678` in region US.
- A local number without its area code, such as `555-0142`.
- Fewer than five digits that Messages has no conversation with. These never have candidates.

Candidates are full numbers on the person's cards or in Messages with those digits.
Ask which one they mean, or for the full number with its country code. Never add a country code yourself.

## Shared numbers

A number on several contact cards, such as a family landline, names nobody:

- The person object has the formatted number as `name`, `ambiguous: true`, and `possible_contacts` listing every card.
- Naming one card, as in `tincan read "Jordan Lee" -j`, finds it, but adds `shared_with` for the other cards.
- A `shared_address` warning names the cards, including for a group member or reactor on such a number.
- A name that matches only cards with exactly the same addresses means that number, as if you typed it.

What to do:

1. Report the number, and name every card that has it. Don't pick one.
2. Messages and calls on it could be from any of them. A message to it reaches whoever uses it.
3. Ask before sending to it. `tincan contacts duplicates -j` shows cards that share addresses.

## Other signals

- `match: "national"`: the card matched only without a country code. Likely, but less certain; say so when it matters.
- A bare number in `from` is someone without exactly one card. Don't name them.
- `contacts_unavailable`: tincan can't read Contacts, so everyone shows as a number. Don't infer names.
- Messages carry only `from` and `from_address`. Never state who wrote a message beyond that.
- `not_found` (exit 3): nothing matches. Ask the person, or look them up with `tincan contacts <query> -j`.
