## PR #1214 Review: Respect manually selected account type in SimpleFIN liability logic

### Summary

Fixes #868 where Discover checking/savings accounts had inverted balances because the mapper incorrectly inferred them as liabilities. The fix prioritizes the user's manually selected account type over mapper inference.

### Assessment: Approve

The core logic change is correct. When `account.accountable_type` is present, use the linked type's liability classification; otherwise fall back to mapper inference. This properly trusts user-selected account types.

### Tests look good

The two new tests properly verify both directions: depository overrides mapper (positive balance preserved) and credit card overrides mapper (balance inverted). The old "mislinked" test is correctly replaced.

### Follow-up suggestion: Replace hardcoded liability type lists with `.classification`

All sync providers (SimpleFIN, Plaid, Lunchflow, Enable Banking, Mercury) hardcode `["CreditCard", "Loan"]` for liability detection, which misses `OtherLiability`. Rather than expanding the list, the existing `Accountable` concern already provides `classification`:

```ruby
# Current (fragile — must update when new liability types are added):
is_linked_liability = ["CreditCard", "Loan"].include?(account.accountable_type)

# Suggested (self-maintaining — uses the domain model):
is_linked_liability = account.accountable_type.present? &&
  account.accountable_type.constantize.classification == "liability"
```

This is a cross-provider refactor and out of scope for this PR. Recommend a follow-up PR to address it across all 5 providers.
