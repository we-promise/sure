## PR #1130 Review: Add Default User Account & Consolidate Account Actions

### Summary
This PR adds the ability for users to designate a default account (depository or credit card) that auto-selects in the transaction form, and consolidates scattered hover-revealed account action icons into a dropdown menu.

---

### Positive Aspects

1. **Good domain modeling** — `supports_default?` and `eligible_for_transaction_default?` on `Account` follow the project convention of models answering questions about themselves
2. **Proper DB-level safety** — `ON DELETE SET NULL` ensures deleted default accounts don't leave dangling references
3. **Family scoping in `default_account_for_transactions`** — The `family_id == family_id` check prevents cross-family data leakage
4. **i18n coverage** — Four languages updated consistently
5. **Menu consolidation** — Cleaner UX replacing hover-revealed icons with a structured dropdown
6. **Good test coverage** — Tests for the happy path, disabled accounts, and linked accounts

---

### Issues Found

#### 1. Security: Missing authorization check in `set_default` (Medium)
**File:** `app/controllers/accounts_controller.rb:91-98`

The `set_default` action uses `set_account` which scopes to `family.accounts.find(params[:id])`, so it's family-scoped. However, there's no check that the account belongs to the *current user's* family vs. just the current session's family. This matches the existing pattern in the controller, so it's consistent — but worth noting for awareness.

#### 2. Missing "Unset Default" functionality (Medium - UX)
**File:** `app/views/accounts/_account.html.erb:74-82`

There's no way to *clear* the default account once set. If a user no longer wants any account pre-selected, they're stuck. The greyed-out "Set as default" item for the current default should either toggle it off or there should be a separate "Remove default" option.

**Suggestion:** Add an `unset_default` action or make `set_default` toggle behavior (if already default, clear it).

#### 3. Hardcoded string in custom menu content (Low)
**File:** `app/views/accounts/_account.html.erb:78`

```erb
<span class="text-sm text-primary"><%= t("accounts.account.set_default") %></span>
```

This is correctly using i18n — good. But the greyed-out item is built with `with_custom_content` instead of using the menu's built-in disabled state (if one exists). This creates a visual inconsistency risk if the menu component's styling changes.

#### 4. Duplicated eligibility logic (Low)
**File:** `app/models/user.rb:252`

```ruby
return nil unless account&.supports_default? && account.active? && !account.linked? && account.family_id == family_id
```

This duplicates `Account#eligible_for_transaction_default?` plus adds the `family_id` check. Consider:

```ruby
def default_account_for_transactions
  return nil unless default_account_id.present?
  account = default_account
  return account if account&.eligible_for_transaction_default? && account.family_id == family_id
end
```

This keeps the eligibility logic in one place and makes the family check the only addition.

#### 5. `institution_name` displayed twice on mobile (Low)
**File:** `app/views/accounts/_account.html.erb:27,35`

The institution name is rendered twice — once hidden on mobile (`hidden sm:inline`) and once hidden on desktop (`sm:hidden`). This works but is slightly unusual. A simpler approach would be to keep the original single rendering and just adjust the layout for mobile.

#### 6. Test for `set_default` doesn't verify eligibility guard (Low)
**File:** `test/controllers/accounts_controller_test.rb:180-185`

The test only covers the happy path. There's no test for the eligibility rejection (e.g., trying to set an investment account as default). Consider adding:

```ruby
test "set_default rejects ineligible account type" do
  investment = accounts(:investment)  # or appropriate fixture
  patch set_default_account_url(investment)
  assert_redirected_to accounts_path
  assert_equal t("accounts.set_default.depository_only"), flash[:alert]
end
```

#### 7. Schema version mismatch (Nitpick)
**File:** `db/schema.rb`

The migration is `20260305120000` but the schema version shows `2026_03_14_131357`. This is fine — it just means there are later migrations on `main`. Just ensure the migration runs cleanly in sequence.

#### 8. Menu `max_width` uses string interpolation into `style` attribute (Nitpick)
**File:** `app/components/DS/menu.html.erb:15`

```erb
style: ("max-width: #{max_width}" if max_width)
```

Since `max_width` only comes from developer-controlled component instantiation (not user input), this is safe. However, adding a simple format validation in the component initializer (e.g., must match `/\A[\d.]+(px|rem|em|%)\z/`) would be defensive.

---

### Verdict

**Approve with suggestions.** The core implementation is solid and follows project conventions well. The main actionable items are:

1. **Add "unset default" capability** — Important UX gap
2. **DRY up the eligibility check** in `User#default_account_for_transactions`
3. **Add negative test case** for the eligibility guard in the controller test

The rest are minor polish items that could be addressed in follow-up PRs.
