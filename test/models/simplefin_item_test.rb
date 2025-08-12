require "test_helper"

class SimplefinItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Connection",
      access_url: "https://example.com/access_token"
    )
  end

  test "belongs to family" do
    assert_equal @family, @simplefin_item.family
  end

  test "has many simplefin_accounts" do
    account = @simplefin_item.simplefin_accounts.create!(
      name: "Test Account",
      account_id: "test_123",
      currency: "USD",
      account_type: "checking",
      current_balance: 1000.00
    )

    assert_includes @simplefin_item.simplefin_accounts, account
  end

  test "has good status by default" do
    assert_equal "good", @simplefin_item.status
  end

  test "can be marked for deletion" do
    refute @simplefin_item.scheduled_for_deletion?

    @simplefin_item.destroy_later

    assert @simplefin_item.scheduled_for_deletion?
  end

  test "is syncable" do
    assert_respond_to @simplefin_item, :sync_later
    assert_respond_to @simplefin_item, :syncing?
  end

  test "scopes work correctly" do
    # Create one for deletion
    item_for_deletion = SimplefinItem.create!(
      family: @family,
      name: "Delete Me",
      access_url: "https://example.com/delete_token",
      scheduled_for_deletion: true
    )

    active_items = SimplefinItem.active
    ordered_items = SimplefinItem.ordered

    assert_includes active_items, @simplefin_item
    refute_includes active_items, item_for_deletion

    assert_equal [ @simplefin_item, item_for_deletion ].sort_by(&:created_at).reverse,
                 ordered_items.to_a
  end
end
