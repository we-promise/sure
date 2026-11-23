# Bank email alerts

Many banks have no open-banking API available to individuals but email an alert
for every transaction. The Email alerts provider turns those emails into
transactions on linked accounts.

```
bank ──alert──▶ your mailbox ──filter/forward──▶ inbound address
     ──mail worker──▶ POST /webhooks/email_alerts/<token> ──▶ Sure
```

## Supported institutions

| Institution | Sender | Alerts | Balance |
| --- | --- | --- | --- |
| GTBank (Nigeria) | `GeNS@gtbank.com` | credits, debits, fees (NIP commission, VAT) | current balance on every alert |
| OPay (Nigeria) | `no-reply@opay-nigeria.com` | transfers and payments (OPay does not email credits) | available balance on every alert |
| Grey | `hello@grey.co` | wallet funding, withdrawals, virtual card spend, per currency wallet | not included |

Each parser lives in `app/models/email_alert/parsers/`. A parser declares the
domains it trusts and maps one email to an `EmailAlert::ParsedAlert`.

## Security model

- The inbound URL carries a random per-connection token. Anyone holding it can
  submit mail, so it is treated as a secret and can be regenerated.
- Every alert must carry a valid **DKIM signature from the institution's own
  domain** (`EmailAlert::DkimVerifier`). Forwarding preserves the original
  signature, so a forged "bank alert" sent straight to the inbound address is
  rejected even if the token leaks. Signatures using the `l=` tag are refused.
- Mail from senders without a parser is answered with `200 {"status":"ignored"}`
  and never stored.
- Raw messages are stored encrypted, so a parser fix can be replayed against
  mail that already arrived.

## Setup

1. In Sure, open **Settings → Bank sync → Email alerts** and create a
   connection. Copy the inbound URL.
2. Deploy `docs/providers/email-alerts/cloudflare-worker.js` as a Cloudflare
   Email Worker (or any relay that POSTs the raw RFC 822 message, unmodified,
   with `Content-Type: message/rfc822`). Set `SURE_WEBHOOK_URL` to the inbound
   URL and optionally `FORWARD_TO` to a verified address for non-alert mail.
3. In Cloudflare Email Routing, route an address (for example
   `alerts-<random>@example.com`) to the worker.
4. In Gmail, add that address under **Settings → Forwarding**. Gmail sends a
   confirmation email; with `FORWARD_TO` set it reaches your inbox.
5. Create a Gmail filter matching the senders above (for example
   `from:(GeNS@gtbank.com OR no-reply@opay-nigeria.com OR hello@grey.co)`) with
   **Forward it to** the inbound address.
6. When the first alert for an account arrives, the account appears under the
   connection. Link it to a Sure account; alerts received before linking are
   imported on the next sync.

## Behavior

- Each alert is imported once (`external_id` is a fingerprint of the alert), so
  redelivered or re-forwarded mail does not duplicate transactions.
- Fee alerts (GTBank "Commission on NIP Transfer", "VAT", remarks `CHARGES`) are
  separate transactions in the Fees category, matching the bank statement.
- When an alert states a balance, the linked depository account's balance is
  set from the most recent alert, which also corrects for alerts the bank never
  sent (OPay credits).
- History before setup is not available from email; import a statement with
  CSV import for earlier transactions.
