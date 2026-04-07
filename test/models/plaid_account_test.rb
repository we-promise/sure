require "test_helper"

class PlaidAccountTest < ActiveSupport::TestCase
  setup do
    @family_a = families(:dylan_family)
    @family_b = families(:empty)

    @item_a = PlaidItem.create!(
      family: @family_a,
      name: "Family A Bank",
      plaid_id: "item_a_#{SecureRandom.hex(4)}",
      access_token: "token_a"
    )

    @item_b = PlaidItem.create!(
      family: @family_b,
      name: "Family B Bank",
      plaid_id: "item_b_#{SecureRandom.hex(4)}",
      access_token: "token_b"
    )
  end

  test "same plaid_id can be linked under different plaid_items" do
    PlaidAccount.create!(
      plaid_item: @item_a,
      plaid_id: "shared_plaid_acc_1",
      name: "Checking",
      plaid_type: "depository",
      currency: "USD",
      current_balance: 5000
    )

    assert_difference "PlaidAccount.count", 1 do
      PlaidAccount.create!(
        plaid_item: @item_b,
        plaid_id: "shared_plaid_acc_1",
        name: "Checking",
        plaid_type: "depository",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same plaid_id cannot appear twice under the same plaid_item" do
    PlaidAccount.create!(
      plaid_item: @item_a,
      plaid_id: "duplicate_plaid",
      name: "Checking",
      plaid_type: "depository",
      currency: "USD",
      current_balance: 1000
    )

    duplicate = PlaidAccount.new(
      plaid_item: @item_a,
      plaid_id: "duplicate_plaid",
      name: "Checking",
      plaid_type: "depository",
      currency: "USD",
      current_balance: 1000
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:plaid_id], "has already been taken"

    assert_raises(ActiveRecord::RecordInvalid) do
      PlaidAccount.create!(
        plaid_item: @item_a,
        plaid_id: "duplicate_plaid",
        name: "Checking",
        plaid_type: "depository",
        currency: "USD",
        current_balance: 1000
      )
    end
  end
end
