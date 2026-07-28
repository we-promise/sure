require "test_helper"

class PluggyAccountTest < ActiveSupport::TestCase
  test "upsert_from_pluggy maps fields and links pluggy_item" do
    item = pluggy_items(:one)
    data = {
      "id" => "pa-9", "name" => "Checking", "balance" => 123.45,
      "currencyCode" => "BRL", "type" => "BANK", "subtype" => "CHECKING",
      "number" => "1234", "status" => "ACTIVE"
    }

    account = PluggyAccount.upsert_from_pluggy!(data, pluggy_item: item)

    assert_equal "pa-9", account.pluggy_account_id
    assert_equal "Checking", account.name
    assert_equal 123.45, account.current_balance
    # Pluggy exposes currency on `currencyCode`, NOT `currency` — must honor it (regression guard).
    assert_equal "BRL", account.currency
    assert_equal "BANK", account.account_type
    assert_equal "ACTIVE", account.account_status
    assert_equal "1234", account.account_number
    assert_equal item.id, account.pluggy_item_id
  end

  test "upsert_from_pluggy is idempotent by pluggy_account_id" do
    item = pluggy_items(:one)
    data = { "id" => "pa-9", "name" => "A", "currencyCode" => "BRL" }

    PluggyAccount.upsert_from_pluggy!(data, pluggy_item: item)
    assert_no_difference "PluggyAccount.where(pluggy_account_id: 'pa-9').count" do
      PluggyAccount.upsert_from_pluggy!(data.merge("name" => "A2"), pluggy_item: item)
    end

    assert_equal "A2", PluggyAccount.find_by(pluggy_account_id: "pa-9").name
  end

  test "upsert_pluggy_transactions_snapshot stores raw payload" do
    acct = pluggy_accounts(:one)

    acct.upsert_pluggy_transactions_snapshot!([ { "id" => "t1" } ])

    assert_equal [ { "id" => "t1" } ], acct.reload.raw_transactions_payload
  end
end
