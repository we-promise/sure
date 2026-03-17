## PR #1214 Review: Respect manually selected account type in SimpleFIN liability logic

### Summary

Fixes #868 where Discover checking/savings accounts had inverted balances because the mapper incorrectly inferred them as liabilities. The fix prioritizes the user's manually selected account type over mapper inference.

### Assessment: Approve with minor suggestion

The core logic change is correct. When `account.accountable_type` is present, use the linked type's liability classification; otherwise fall back to mapper inference. This properly trusts user-selected account types.

### Issue: `OtherLiability` missing from liability checks

Line 55 and 66 only check `["CreditCard", "Loan"]` but `Accountable::TYPES` includes `OtherLiability`. Suggest:

```ruby
LIABILITY_TYPES = %w[CreditCard Loan OtherLiability].freeze
```

### Tests look good

The two new tests properly verify both directions: depository overrides mapper (positive balance preserved) and credit card overrides mapper (balance inverted). The old "mislinked" test is correctly replaced.
