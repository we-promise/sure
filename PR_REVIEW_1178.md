# PR Review: #1178 — Remove Blank Amount from Transaction Entry Parameters

## Summary
This PR adds a single defensive line in `TransactionsController#entry_params` to delete the `:amount` key when its value is blank, preventing a `NoMethodError` when downstream code attempts unary negation (`-`) on `nil`.

## Analysis

**The Bug:**
When an empty amount string (`""`) is submitted, Rails type-casting converts it to `nil`. The `monetize :amount` macro on `Entry` generates `amount_money`, which returns `nil` when amount is `nil`. Multiple view templates then call `-entry.amount_money` (e.g., `app/views/transactions/_header.html.erb:6`), causing a `NoMethodError: undefined method '-@' for nil`.

**The Fix:**
```ruby
entry_params.delete(:amount) if entry_params[:amount].blank?
```

This is placed after extracting `:nature` but before the signed-amount logic, so the subsequent `entry_params[:amount].present?` guard naturally skips the sign-conversion block when amount is blank.

## Verdict: Approve with minor suggestions

**The fix is correct and minimal.** It addresses the root cause at the right layer (controller params sanitization) rather than papering over it in the view. The placement is logical — right before the code that would otherwise try `.to_d` on a blank string.

**Minor suggestions (non-blocking):**

1. **Validation already exists** — `Entry` has `validates :amount, presence: true` (entry.rb:13), so even without this fix, a blank amount would fail validation on save. The real issue is that the controller's sign-conversion block would execute on `""` before validation runs. The fix correctly short-circuits this. Just worth noting the defense-in-depth.

2. **Consider a test** — A controller test covering the blank amount scenario would lock this fix in and prevent regressions. Something like:
   ```ruby
   test "handles blank amount gracefully" do
     post transactions_url, params: {
       entry: { name: "Test", date: Date.current, amount: "", currency: "USD", nature: "outflow",
                entryable_type: "Transaction",
                entryable_attributes: { category_id: categories(:food_and_drink).id } }
     }
     # Should not raise NoMethodError — validation failure is expected
     assert_response :unprocessable_entity
   end
   ```

3. **`"".to_d` returns `0`** — Note that `"".to_d` actually returns `BigDecimal("0")` in Ruby, so the `.to_d` call on line 335 wouldn't itself error. The `blank?` check handles both `nil` and `""`, which is the right choice since it prevents a zero-amount entry from being silently created.

Overall this is a clean, focused fix. Ship it.
