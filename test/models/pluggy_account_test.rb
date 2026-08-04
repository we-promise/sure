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

  # Regression for the P1 cross-item scope bug (Codex review): the class entry
  # must scope its find-or-initialize to THIS item's pluggy_accounts. An unscoped
  # `find_or_initialize_by(pluggy_account_id:)` is global, so on a reconnect —
  # the same upstream account linked to a second PluggyItem — it would resolve to
  # the OTHER item's row and the `account.pluggy_item = pluggy_item` write would
  # silently re-parent it, stealing another connection's account. Scoping the
  # lookup to the association makes each item own its own row for the same
  # upstream id; the composite-unique index on [pluggy_item_id, pluggy_account_id]
  # (see migration 20260715155623) enforces this at the DB level.
  test "upsert_from_pluggy scopes the lookup to the given item — a second item can't steal another item's account" do
    item_one = pluggy_items(:one)
    item_two = PluggyItem.create!(
      family: families(:dylan_family),
      name: "Second Pluggy",
      client_id: "c2", client_secret: "s2",
      pluggy_item_id: "item-2", status: :good
    )

    data = { "id" => "pa-shared", "name" => "Shared", "currencyCode" => "BRL", "type" => "BANK" }
    PluggyAccount.upsert_from_pluggy!(data, pluggy_item: item_one)
    row_one = PluggyAccount.find_by(pluggy_item_id: item_one.id, pluggy_account_id: "pa-shared")
    assert_equal item_one.id, row_one.pluggy_item_id

    # Same upstream id under a SECOND item. Under the old unscoped lookup this
    # found row_one globally and re-parented it (overwriting its name + flipping
    # pluggy_item_id to item_two) with no new row created. Scoped to item_two's
    # accounts it must INITIALIZE a new row instead, leaving row_one untouched.
    assert_difference -> { PluggyAccount.where(pluggy_account_id: "pa-shared").count }, +1 do
      PluggyAccount.upsert_from_pluggy!(data.merge("name" => "Shared 2"), pluggy_item: item_two)
    end

    assert_equal item_one.id, row_one.reload.pluggy_item_id
    assert_equal "Shared", row_one.reload.name # untouched — the scoped upsert initialized a separate row
    row_two = PluggyAccount.find_by(pluggy_item_id: item_two.id, pluggy_account_id: "pa-shared")
    assert_equal item_two.id, row_two.pluggy_item_id
    assert_equal "Shared 2", row_two.name
  end

  test "upsert_pluggy_transactions_snapshot stores raw payload" do
    acct = pluggy_accounts(:one)

    acct.upsert_pluggy_transactions_snapshot!([ { "id" => "t1" } ])

    assert_equal [ { "id" => "t1" } ], acct.reload.raw_transactions_payload
  end
end
