# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260927161700_backfill_brokerage_account_id_on_trade_republic_items")

class BackfillBrokerageAccountIdOnTradeRepublicItemsMigrationTest < ActiveSupport::TestCase
  test "claims the brokerage account id from an already-synced legacy item" do
    item = trade_republic_items(:configured_item)
    assert_nil item.brokerage_account_id

    run_migration

    assert_equal "DE1234", item.reload.brokerage_account_id
  end

  test "leaves an item with no synced accounts unclaimed" do
    item = trade_republic_items(:no_session_item).family.trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "never-synced"
    )

    run_migration

    assert_nil item.reload.brokerage_account_id
  end

  test "does not overwrite an id already claimed by a fresh connection" do
    item = trade_republic_items(:configured_item)
    item.update_column(:brokerage_account_id, "DE9999")

    run_migration

    assert_equal "DE9999", item.reload.brokerage_account_id
  end

  test "gives a shared account to the oldest active item only" do
    oldest = trade_republic_items(:configured_item)
    duplicate = oldest.family.trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "session"
    )
    duplicate.trade_republic_accounts.create!(
      kind: "portfolio", trade_republic_account_id: "DE1234", currency: "EUR", raw_positions_payload: [], raw_timeline_payload: []
    )

    run_migration

    assert_equal "DE1234", oldest.reload.brokerage_account_id
    assert_nil duplicate.reload.brokerage_account_id
  end

  test "skips an account another active item already claimed" do
    claimed = trade_republic_items(:requires_update_item)
    claimed.update_column(:brokerage_account_id, "DE1234")

    run_migration

    assert_nil trade_republic_items(:configured_item).reload.brokerage_account_id
    assert_equal "DE1234", claimed.reload.brokerage_account_id
  end

  test "leaves items scheduled for deletion unclaimed" do
    item = trade_republic_items(:configured_item)
    item.update_column(:scheduled_for_deletion, true)

    run_migration

    assert_nil item.reload.brokerage_account_id
  end

  test "can be run again" do
    item = trade_republic_items(:configured_item)

    2.times { run_migration }

    assert_equal "DE1234", item.reload.brokerage_account_id
  end

  private

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        BackfillBrokerageAccountIdOnTradeRepublicItems.new.up
      end
    end
end
