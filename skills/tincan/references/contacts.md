# Contacts

How to find, add and edit cards in Apple Contacts with tincan.
Changes sync to the person's devices, so change a card only when the person asks. Always add `--json` (`-j`).

## Find and show

- `tincan contacts <query> -j` searches names, nicknames, companies, numbers and emails. It is `contacts find`.
- Without a query it lists every card, 25 at a time; `--limit` shows more.
- A number of seven or more digits without its area or country code finds cards whose numbers end with it.
- `tincan contacts show <who> -j` shows one card. It never picks between cards: several stop with `ambiguous`.
- A card has `ref`, `name`, and when set `given_name`, `middle_name`, `family_name`, `nickname`, `organization`,
  `job_title`, `is_organization`, `phones` (`label`, `value`, `normalized`), `emails` (`label`, `value`), `birthday`.
- `tincan who <who> -j` adds the person's conversations and calls.

## Duplicates

- `tincan contacts duplicates -j` lists cards that share a number or email, then cards with the same name.
- Each group has `kind` (`shared_address` or `same_name`), `shared_addresses`, `names_match` and `cards`.
- Each card has `conversations` and `last_activity` when Messages can be read.
- tincan never merges or picks. Explain the evidence, and leave merging to the person:
  Contacts, then Card, then Look for Duplicates.

## Change a card

1. Change a card only on the person's explicit request.
2. Preview with `--dry-run -j` and show the person the change and every warning.
3. After approval, run the same command with `--yes` (`-y`) in place of `--dry-run`.
   Without it, nothing changes (`confirmation_required`, exit 3).

Add a card:

- `tincan contacts add --name "Maya Chen" --phone mobile:+14155550142 --dry-run -j`
- `--name` takes a full name and uses its last word as the family name. `--first` and `--last` set them exactly.
- Also `--nickname`, `--org`, `--title`, `--email` and `--birthday`. `--phone` and `--email` repeat.
- Labels go before a colon: `mobile:`, `home:`, `work:`, `iphone:`, `main:`, `school:`, `other:`, or the person's own.
- Birthdays are `YYYY-MM-DD`, or `MM-DD` without a year.

Edit a card:

- `tincan contacts edit <who> --add-email work:maya.chen@example.com --dry-run -j`
- Only the fields you pass change: `--first`, `--middle`, `--last`, `--nickname`, `--org`, `--title`, `--birthday`.
- An empty value clears a field: `--nickname ""`.
- `--add-phone`, `--remove-phone`, `--add-email` and `--remove-email` repeat. Removing matches the number however it is written,
  with the same extension, if any.
- To relabel, remove and add in one command: `--remove-phone +14155550188 --add-phone work:+14155550188`.
- Adding an address the card has, or giving one twice, fails with `invalid_input` (exit 64).
- Before saving, tincan backs up the card as a vCard; the result's `backup` names the file.
- A dry run's `after` is the card as it would be saved; `changes` lists each change.

## Warnings and refusals

| Code | Do |
| --- | --- |
| `duplicate_contact` (exit 3) | A card already has that number or email. Suggest editing it. Pass `--allow-duplicate` only after the person confirms a second card. |
| `same_name_exists` | A card has this name. Ask whether it is the same person before adding. |
| `address_in_use` | Conversations use an address being removed; `addresses_in_use` lists them. Show the person which change. |
| `shared_address` | An address you add is on other cards; name them. |
| `incomplete_number` (exit 3) | A number without its country code. Ask for the full number. |
| `contact_not_found` (exit 3) | No card has that `contact:<id>`. Find it with `tincan contacts <query> -j`. |
| `contacts_access_required` (exit 4) | The app that runs you lacks Contacts. Relay the `fix` from `tincan doctor -j` to the person. |
| `backup_failed`, `contacts_save_failed` (exit 1) | Nothing changed. Tell the person the message. |
