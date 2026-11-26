# Verified investment snapshots

Some SimpleFIN connections provide transaction activity but do not provide a reliable investment portfolio. A self-hosted operator can publish a complete dated brokerage observation without unlinking the account or re-entering its ledger. Use this only when the brokerage, not the feed, is authoritative for holdings, cash and total market value.

## What changes

- The account's holdings, cash and total are shown **as of the observation date**. They will not track later market moves or portfolio activity until another complete observation is published.
- SimpleFIN can still fetch and process activity. It does not replace the selected positions or cash, and Sure does not rebuild the investment balance history while a verified snapshot is active.
- Older holdings and balances stay in history. A later observation represents the full portfolio: omission closes the position in the current view without deleting historical rows. Reported zero cost basis and unknown cost basis are distinct.
- The holdings history API is date-based, not a current-position endpoint. For an all-cash observation, request its date to distinguish the empty position set from earlier holdings.

## Publishing

Back up the database and rehearse with an isolated restore. Work as a trusted operator and confirm the account belongs to the intended household, currency, and sole SimpleFIN link. An observation must contain real security IDs, quantities, values and posted cash in that account's currency. Include settlement cash once; do not count it as both a holding and cash. Do not infer missing basis from the amount invested. Preserve the source export separately.

From the Rails console, pass decimal strings (and `nil` for an unreported cost basis):

```ruby
account = Account.find("<confirmed account id>")
security = Security.find("<confirmed security id>")
Account::VerifiedInvestmentSnapshot.new(account).publish!(
  date: Date.current,
  total: "1000.00",
  cash: "100.00",
  positions: [
    { security_id: security.id, qty: "2", amount: "900.00", price: "450.00", cost_basis: nil }
  ]
)
```

Publication is atomic and refuses inconsistent totals, duplicate securities, future dates, revisions on the same date, or existing holding/balance observations on or after that date. Do not work around a collision by deleting history or attributing the snapshot to the feed. Investigate the conflict before publishing.
