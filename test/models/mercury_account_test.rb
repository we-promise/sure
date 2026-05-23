require "test_helper"

class MercuryAccountTest < ActiveSupport::TestCase
  setup do
    @family_a = families(:dylan_family)
    @family_b = families(:empty)

    @item_a = MercuryItem.create!(
      family: @family_a,
      name: "Family A Mercury",
      token: "token_a",
      base_url: "https://api-sandbox.mercury.com/api/v1",
      status: "good"
    )

    @item_b = MercuryItem.create!(
      family: @family_b,
      name: "Family B Mercury",
      token: "token_b",
      base_url: "https://api-sandbox.mercury.com/api/v1",
      status: "good"
    )
  end

  test "same account_id can be linked under different mercury_items" do
    MercuryAccount.create!(
      mercury_item: @item_a,
      account_id: "shared_merc_acc_1",
      name: "Checking",
      currency: "USD",
      current_balance: 5000
    )

    # A second family connecting the same Mercury account must succeed and produce
    # an independent ledger (separate MercuryAccount row, separate Account).
    assert_difference "MercuryAccount.count", 1 do
      MercuryAccount.create!(
        mercury_item: @item_b,
        account_id: "shared_merc_acc_1",
        name: "Checking",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same account_id can be linked under different mercury_items in the same family" do
    item_a_2 = MercuryItem.create!(
      family: @family_a,
      name: "Family A Second Mercury",
      token: "token_a_2",
      base_url: "https://api-sandbox.mercury.com/api/v1",
      status: "good"
    )

    MercuryAccount.create!(
      mercury_item: @item_a,
      account_id: "shared_merc_acc_1",
      name: "Checking",
      currency: "USD",
      current_balance: 5000
    )

    assert_difference "MercuryAccount.count", 1 do
      MercuryAccount.create!(
        mercury_item: item_a_2,
        account_id: "shared_merc_acc_1",
        name: "Checking",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same account_id cannot appear twice under the same mercury_item" do
    MercuryAccount.create!(
      mercury_item: @item_a,
      account_id: "duplicate_acc",
      name: "Checking",
      currency: "USD",
      current_balance: 1000
    )

    duplicate = MercuryAccount.new(
      mercury_item: @item_a,
      account_id: "duplicate_acc",
      name: "Checking",
      currency: "USD",
      current_balance: 1000
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:account_id], "has already been taken"

    assert_raises(ActiveRecord::RecordInvalid) do
      MercuryAccount.create!(
        mercury_item: @item_a,
        account_id: "duplicate_acc",
        name: "Checking",
        currency: "USD",
        current_balance: 1000
      )
    end
  end
end
