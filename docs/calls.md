# Call history

[← tincan](../README.md)

tincan reads the phone and FaceTime call history your iPhone syncs to this Mac, read-only, names each caller from Apple Contacts, and tells you whether you got back to a missed call.

```sh
tincan calls
tincan calls --missed --since 7d
tincan calls Maya
tincan calls chat:4
```

Call history needs Full Disk Access, like Messages, and an iPhone signed in to the same Apple Account with iCloud and Continuity on. Without it, tincan reports `call_history_missing`.

## List calls

```text
$ tincan calls --limit 9
↙ Sam Rivera           42s · WhatsApp                  20m ago
↙ Unknown caller       Missed                          40m ago
↗ Maya Chen, Sam Park  10m 00s · FaceTime audio       10:20 AM
↙ +1 (415) 555-0111    Missed · junk                   9:50 AM
↗ Ava 🌸 Lin           No answer                       9:20 AM
↙ 健二 佐藤            3m 05s · FaceTime video         8:50 AM
↙ +1 (415) 555-0122    Missed · not returned           8:20 AM
↙ Northwind Dental     Missed · not returned           7:20 AM
↙ Sam Park             Missed · texted back in 1h 4m   5:20 AM
Earlier: tincan calls --before 2026-09-23T05:20:27.000-07:00 --limit 9
```

Calls are newest first, 25 by default. `↙` is incoming and `↗` outgoing; FaceTime and calls through other apps say which. A name appears only when exactly one card has the number. A hidden or unknown number is `Unknown caller`. An outgoing call without talk time is `No answer`: Apple doesn't record whether it was unanswered, busy or cancelled.

| Option | Shows |
| --- | --- |
| `<person>` | Calls with every address the person uses. For a one-to-one `chat:<id>`, every address of the person behind it; for a group, the people in it. |
| `--missed` | Only missed calls |
| `--since <time>`, `--before <time>` | A [time](reference.md#times) range. `Earlier:` gives the command for the next page. |
| `-n`, `--limit <n>` | How many |

As everywhere, tincan never picks a caller: an ambiguous name or an [incomplete number](people.md#numbers-without-a-country-code) exits 3 with candidates, and a number on several cards gets a `shared_address` warning. The JSON fields are in the [reference](reference.md#calls).

## Did I get back to them?

For each missed call, tincan looks for the first thing you did afterwards: a call to that person on any of their numbers, or a message in any one-to-one conversation with them. It shows `called back in 5m` or `texted back in 1h 4m`, or else `not returned`, unless the call was junk. A hidden number has nothing to match, so it shows only `Missed`. When Messages can't be read, a `messages_unavailable` warning says texts back weren't checked.

`tincan` on its own lists up to five missed calls from the last seven days that you haven't returned, leaving out junk. `who` shows the total, how many were missed, including returned ones, and the five most recent calls.

Exclusions cover messages, not calls: `calls` and `who` still show calls with an excluded person, but messages in excluded conversations don't count as a reply, and an excluded `chat:<id>` can't be named (`excluded`); name the person instead.
