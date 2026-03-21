# PR #1237 Review: Normalize legacy rule condition types

## Critical Issue: `transaction_details` is NOT a legacy alias for `transaction_name`

This PR treats `transaction_details` as a legacy/renamed version of `transaction_name`, but they are **semantically distinct filters** that query entirely different data:

| Filter | Database Field | Purpose |
|--------|---------------|---------|
| `transaction_name` | `entries.name` (text column) | Matches against the user-facing transaction name |
| `transaction_details` | `transactions.extra` (JSONB column) | Matches against provider metadata (SimpleFIN payee, description, memo, etc.) |

Both filters are **actively registered** in `Rule::Registry::TransactionResource#condition_filters` (`app/models/rule/registry/transaction_resource.rb`). This means `transaction_details` is a current, functional filter — not a legacy type.

### Impact of this PR as-is:

1. **The migration** (`20260321003133`) would silently convert all existing `transaction_details` conditions to `transaction_name`, **breaking** any rules that rely on matching provider metadata in the `extra` JSONB field. Users' rules would start matching against `entries.name` instead — a completely different column with different data.

2. **The `before_validation` callback** in `Rule::Condition` would prevent anyone from ever creating a `transaction_details` condition again, even though the filter class still exists and is registered.

3. **The registry fallback** in `get_filter!` would silently redirect lookups for `transaction_details` to the `transaction_name` filter, masking the issue.

### Regarding `"name"` → `"transaction_name"`

Mapping legacy `"name"` to `"transaction_name"` seems reasonable — there is no separate `name` filter registered, and this appears to be a genuine rename. However, I'd recommend:

- Adding a test that confirms `"name"` is not a registered filter key
- Only normalizing `"name"`, **not** `"transaction_details"`

### Code duplication

The legacy mapping logic (`case` statement) is duplicated across three locations:
- `Rule::Condition#normalize_condition_type`
- `Rule::Registry#get_filter!`
- The migration SQL

Extract this to a shared constant, e.g.:

```ruby
# In Rule::Condition or a shared concern
LEGACY_CONDITION_TYPES = { "name" => "transaction_name" }.freeze
```

### Recommendations

1. **Remove `"transaction_details"` from the mapping entirely** — it is a distinct, active filter
2. **Keep only the `"name"` → `"transaction_name"` normalization** if there is evidence of legacy `"name"` values in production data
3. **Add tests** covering the normalization behavior and ensuring `transaction_details` conditions continue to work
4. **Extract the mapping** to a single constant to avoid duplication
5. **Make the migration reversible** or at minimum scope it to only normalize `"name"` values

### Summary

**Requesting changes.** The `"name"` normalization is fine, but including `"transaction_details"` would silently break existing rules by changing what data they match against. This needs to be separated out before merging.
