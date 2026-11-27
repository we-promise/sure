# Setting Up Fio banka (Czechia)

[Fio banka](https://www.fio.cz/) exposes an API for reading movements from your own
accounts. You bring your own token, so Sure talks to Fio directly on your behalf — no
third-party aggregator sits in between, and no consent expires every 90 days.

> [!NOTE]
> A token grants access to **one account**. If you track three Fio accounts in Sure, you
> generate three tokens and add three connections.

## 1. Get Your Token

1. Sign in to Fio internet banking.
2. Open **Nastavení** (top right), then the **API** tab.
3. Create a token with the **Sledování účtu** (account monitoring) right. That is
   read-only; Sure never initiates payments, and a token without payment rights cannot
   be abused to move money.
4. Authorize the request — Fio requires SMS or push confirmation, and every signatory
   has to sign on jointly held accounts.
5. Wait five minutes. Fio rejects a brand-new token until then.

Every token must have an expiry, at most **180 days**. Choose automatic renewal if you
do not want to repeat this twice a year: Fio then extends the token by 180 days on each
internet or smart banking login.

## 2. Add Fio to Sure

1. In Sure, go to **Settings > Providers** and find the **Fio banka** panel.
2. Paste the token and save.
3. The first sync reads the statement header, which is the only account description Fio
   offers, and the account appears for setup. Link it to an existing Sure account or
   create a new one from it.

Fio reports no account type, so the account is offered as a current account. Pick a loan
instead if the token belongs to a mortgage, loan or overdraft account — Fio reports those
balances negative, and Sure stores a liability as a positive balance.

## 3. Syncing

One property of the API shapes everything: a token may be used **once per 30 seconds**,
for reading or writing, whatever the format. So a sync spends exactly one request.

- Each sync asks for the movements booked between the day the last sync covered and
  today, then processes them.
- The window starts a week before that day rather than after it. Fio books a movement
  under its banking date, which can trail the day it becomes visible.
- Re-reading costs nothing: every movement carries a permanent id (`ID pohybu`), and a
  movement already imported updates its entry rather than duplicating it. A reversal
  gets its own id and arrives as its own entry.

A manual sync started within 30 seconds of a scheduled one is refused by Fio. That is
not an error — nothing is fetched, the connection stays healthy, and the next sync
continues where this one stopped.

Fio has no concept of a pending or held transaction, so nothing is ever badged pending
and nothing has to be reconciled later.

### History older than 90 days

Fio serves 90 days without further authorization. Older movements need the account's
full history unlocked: in internet banking under **Nastavení > API**, click the padlock
on the token and authorize. That opens a **10-minute** window.

Set the connection's start date to how far back you want to go. If that reaches past 90
days and the history is still locked, Fio refuses the period: the sync reports it and
every sync from then on stays inside the 90 days Fio does serve, so you keep getting
recent movements. A sync only ever makes one request — retrying a refused period
immediately would breach the 30-second rule and get a 409 instead.

To collect the rest: unlock the history in internet banking, then press **Sync** on the
connection. That is what tells Sure the unlock happened, and the sync reaches for the
whole range again. Changing the token or the start date does the same.

### What lands in a transaction

Fio returns each movement as numbered columns — the same ids its CSV and XML exports
use. Values below are shaped as the live API returns them, anonymised.

| Fio column | Becomes | Example in | Example out |
| --- | --- | --- | --- |
| `column22` *ID pohybu* | the transaction's provider id | `27707247780` | `fio_27707247780` |
| `column0` *Datum* | date | `"2026-06-27+0200"` | `2026-06-27` |
| `column1` *Objem* | amount | `-958.0` | `958.0` spent |
| `column10` *Název protiúčtu* | name, for transfers | `"Junák - český skaut, z. s."` | same |
| `column7` *Uživatelská identifikace* | name and merchant, for card payments | `"Nákup: BILLA 1234,  NA PRIKOPE 1, PRAHA 1, 11000, CZE, dne 26.6.2026, částka  958.00 CZK"` | `BILLA 1234` |
| `column16` *Zpráva pro příjemce* | notes | `"Záloha na účet tábora"` | same |
| `column18` *Upřesnění* | the original amount of a converted payment | `"15.90 EUR"` | `EUR`, `15.9` |
| `column4` `column5` `column6` *KS/VS/SS*, `column17` *ID pokynu*, `column2`+`column3` | kept on the transaction for rules to match | `"202609"` | `202609` |

Fio does not categorise anything, so nothing arrives with a category. A card payment is
named after the acceptor — only the first field of the receipt line, so every branch of
a chain stays one merchant and your rules only have to be written once. A transfer is
named after the counterparty. Anything with neither, such as a fee or credited interest,
is named after the operation type.

Fio repeats the same text across *Zpráva pro příjemce*, *Komentář* and, on card
payments, *Uživatelská identifikace*. Notes only keep it when it says something the name
does not, so a card payment usually has none. The acceptor's full address stays on the
transaction's provider data, not in the name.

### Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `FIO_INITIAL_HISTORY_DAYS` | `90` | History a new connection reaches for when no start date is set. Above 90 needs an unlock. |
| `FIO_SYNC_LOOKBACK_DAYS` | `7` | Days before the last covered day that every sync re-reads. |
| `FIO_DEBUG_RAW` | unset | Log raw API payloads. Development only — the dump contains counterparty names and payment messages. |

## Troubleshooting

**Connection requires a new token**
Fio answers an unknown, expired or deactivated token with HTTP 500, which Sure reports
as a token problem. Check the token's validity under **Nastavení > API** and paste a new
one into the provider panel.

**The statement is too large**
Fio caps one request at 50 000 movements. Set a later start date on the connection.

**Older transactions are missing**
Either the history was never unlocked (see above), or the connection's start date bounds
it.

**Sync errors**
Provider sync failures and notes are captured in Sure's debug log (super admin:
**Settings > Debug**), filtered by the `fio` provider key. The token is never logged.
