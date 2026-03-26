require "test_helper"

class SnaptradeAccountTest < ActiveSupport::TestCase
  setup do
    @family_a = families(:dylan_family)
    @family_b = families(:empty)

    @item_a = SnaptradeItem.create!(
      family: @family_a,
      name: "Family A Broker",
      client_id: "client_a",
      consumer_key: "key_a",
      status: "good"
    )

    @item_b = SnaptradeItem.create!(
      family: @family_b,
      name: "Family B Broker",
      client_id: "client_b",
      consumer_key: "key_b",
      status: "good"
    )
  end

  test "same snaptrade_account_id can be linked under different snaptrade_items" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "shared_snap_uuid_1",
      name: "IRA",
      currency: "USD",
      current_balance: 5000
    )

    assert_difference "SnaptradeAccount.count", 1 do
      SnaptradeAccount.create!(
        snaptrade_item: @item_b,
        snaptrade_account_id: "shared_snap_uuid_1",
        name: "IRA",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same snaptrade_account_id cannot appear twice under the same snaptrade_item" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )

    duplicate = SnaptradeAccount.new(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:snaptrade_account_id], "has already been taken"

    assert_raises(ActiveRecord::RecordInvalid) do
      SnaptradeAccount.create!(
        snaptrade_item: @item_a,
        snaptrade_account_id: "dup_snap_uuid",
        name: "Brokerage",
        currency: "USD",
        current_balance: 1000
      )
    end
  end
end
