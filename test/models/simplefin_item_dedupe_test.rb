require "test_helper"

class SimplefinItemDedupeTest < ActiveSupport::TestCase
  fixtures :users, :families

  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SF Test",
      access_url: "https://example.com/access"
    )
  end

  test "dedup_simplefin_accounts! collapses duplicate SFAs by upstream account_id and preserves data" do
    # Create two SFAs with the same upstream account_id
    sfa1 = @item.simplefin_accounts.create!(
      name: "Quicksilver",
      account_id: "ACT-123",
      currency: "USD",
      current_balance: 10,
      account_type: "credit"
    )
    sfa2 = @item.simplefin_accounts.build(
      name: "Quicksilver (dup)",
      account_id: "ACT-123",
      currency: "USD",
      current_balance: 10,
      account_type: "credit"
    )
    # Bypass uniqueness validation to simulate historical duplicate rows
    sfa2.save!(validate: false)

    # Link only the first SFA to an Account; leave the duplicate SFA unlinked
    keeper = Account.create!(
      family: @family,
      name: "Keeper QS",
      currency: "USD",
      balance: 0,
      accountable_type: "CreditCard",
      accountable: CreditCard.create!
    )
    # Link via legacy FK to avoid validation collisions in tests
    keeper.update_columns(simplefin_account_id: sfa1.id, updated_at: Time.current)

    stats = @item.dedup_simplefin_accounts!

    # One duplicate SFA should be deleted
    assert_operator stats[:deleted_simplefin_accounts], :>=, 1

    # Only one SFA with the upstream id should remain
    remaining = @item.simplefin_accounts.where(account_id: "ACT-123")
    assert_equal 1, remaining.count
  end
end
