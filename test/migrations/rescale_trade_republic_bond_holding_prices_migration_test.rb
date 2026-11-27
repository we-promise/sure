# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008090000_rescale_trade_republic_bond_holding_prices")

require Rails.root.join("db/migrate/20261123210000_refresh_trade_republic_balances_after_bond_rescale")

class RescaleTradeRepublicBondHoldingPricesMigrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  BOND_ISIN = "IT0005377152"
  STOCK_ISIN = "US0378331005"
  INTEREST_ISIN = "LU0000000001"

  setup do
    @family = families(:dylan_family)
    @item = trade_republic_items(:configured_item)
    @item.trade_republic_accounts.destroy_all

    @tr_account = @item.trade_republic_accounts.create!(
      name: "Bond Test",
      trade_republic_account_id: "DEBOND1",
      currency: "EUR",
      raw_positions_payload: [
        { "isin" => BOND_ISIN, "category" => "interest_products", "quantity" => "2677.95", "average_cost" => "0.93", "price" => "84.04" },
        { "isin" => STOCK_ISIN, "category" => "brokerage", "quantity" => "10", "average_cost" => "1.50", "price" => "183.94" },
        { "isin" => INTEREST_ISIN, "category" => "interest_products", "quantity" => "5", "average_cost" => "100.00", "price" => "101.20" }
      ]
    )
    @account = @family.accounts.create!(
      name: "Trade Republic Bond Test", balance: 0, cash_balance: 0, currency: "EUR", accountable: Investment.new
    )
    @tr_account.ensure_account_provider!(@account)
    @tr_account.reload
  end

  teardown do
    Account.reset_column_information
    TradeRepublicItem.reset_column_information
  end

  test "rescales holdings before the account logo selection column exists" do
    holding = create_snapshot(BOND_ISIN, Date.current, qty: "2677.95", price: "84.04", cost_basis: "0.93")

    # This later column is absent on upgrades, but present in CI's schema dump.
    # PostgreSQL restores it when the test transaction rolls back.
    Account.connection.remove_column(:accounts, :logo_selection)
    Account.reset_column_information

    assert_no_difference -> { @item.syncs.count } do
      run_migration
    end

    assert_equal BigDecimal("0.8404"), holding.reload.price
    assert_equal BigDecimal("2250.5492"), holding.amount
    assert_equal "0.8404", @tr_account.reload.raw_positions_payload.first["price"]
  end

  test "does not schedule a sync before later Trade Republic item columns exist" do
    holding = create_snapshot(BOND_ISIN, Date.current, qty: "2677.95", price: "84.04", cost_basis: "0.93")

    # Upgrades from before these migrations run this one first. PostgreSQL
    # restores the columns when the test transaction rolls back.
    connection = TradeRepublicItem.connection
    %i[timeline_cursors device_id session_expires_at].each do |column|
      connection.remove_column(:trade_republic_items, column)
    end
    TradeRepublicItem.reset_column_information

    assert_no_difference -> { Sync.where(syncable: @item).count } do
      run_migration
    end

    assert_equal BigDecimal("0.8404"), holding.reload.price
  end

  test "rescales bond snapshots stored at percent of par" do
    older = create_snapshot(BOND_ISIN, 3.days.ago.to_date, qty: "2677.95", price: "83.10", cost_basis: "0.93")
    latest = create_snapshot(BOND_ISIN, Date.current, qty: "2677.95", price: "84.04", cost_basis: "0.93")

    run_migration

    assert_equal BigDecimal("0.831"), older.reload.price
    assert_equal BigDecimal("2225.3765"), older.amount
    assert_equal BigDecimal("0.8404"), latest.reload.price
    assert_equal BigDecimal("2250.5492"), latest.amount
  end

  test "falls back to the position's average buy-in when the snapshot has no cost basis" do
    holding = create_snapshot(BOND_ISIN, Date.current, qty: "2677.95", price: "84.04", cost_basis: nil)

    run_migration

    assert_equal BigDecimal("0.8404"), holding.reload.price
  end

  test "leaves per-unit prices, other categories and other providers alone" do
    corrected = create_snapshot(BOND_ISIN, Date.current, qty: "2677.95", price: "0.8404", cost_basis: "0.93")
    stock = create_snapshot(STOCK_ISIN, Date.current, qty: "10", price: "183.94", cost_basis: "1.50")
    interest = create_snapshot(INTEREST_ISIN, Date.current, qty: "5", price: "101.20", cost_basis: "100.00")
    calculated = create_snapshot(BOND_ISIN, 5.days.ago.to_date, qty: "2677.95", price: "84.04", cost_basis: "0.93",
      external_id: nil, account_provider_id: nil)

    run_migration

    assert_equal BigDecimal("0.8404"), corrected.reload.price
    assert_equal BigDecimal("183.94"), stock.reload.price
    assert_equal BigDecimal("101.2"), interest.reload.price
    assert_equal BigDecimal("84.04"), calculated.reload.price
  end

  test "rescales sold bonds kept on the shared BOND security" do
    shared_bond = Security.create!(ticker: "BOND", exchange_operating_mic: "XHAM", name: "Bond")
    sold = create_snapshot("DE0001102580", 30.days.ago.to_date, qty: "1000", price: "97.50", cost_basis: "0.96",
      security: shared_bond)
    sold_without_cost = create_snapshot("DE0001102598", 31.days.ago.to_date, qty: "1000", price: "97.50", cost_basis: nil,
      security: shared_bond)

    run_migration

    assert_equal BigDecimal("0.975"), sold.reload.price
    assert_equal BigDecimal("975"), sold.amount
    assert_equal BigDecimal("97.5"), sold_without_cost.reload.price
  end

  test "rescales percent quotes in the stored portfolio payload" do
    run_migration

    prices = @tr_account.reload.raw_positions_payload.to_h { |position| [ position["isin"], position["price"] ] }
    assert_equal "0.8404", prices[BOND_ISIN]
    assert_equal "183.94", prices[STOCK_ISIN]
    assert_equal "101.20", prices[INTEREST_ISIN]
  end

  test "leaves unlinked portfolio payloads alone" do
    @tr_account.account_provider.destroy!

    assert_no_difference -> { @item.syncs.count } do
      run_migration
    end

    assert_equal "84.04", @tr_account.reload.raw_positions_payload.first["price"]
  end

  test "leaves sync scheduling to the later migration even when rerun" do
    create_snapshot(BOND_ISIN, Date.current, qty: "2677.95", price: "84.04", cost_basis: "0.93")

    assert_no_difference -> { @item.syncs.count } do
      run_migration
    end
    assert_no_difference -> { @item.syncs.count } do
      run_migration
    end
  end

  test "refreshes corrected portfolios only after the item schema migrations" do
    connection = TradeRepublicItem.connection
    %i[device_id session_expires_at].each do |column|
      connection.remove_column(:trade_republic_items, column)
    end
    TradeRepublicItem.reset_column_information

    assert_no_enqueued_jobs only: SyncJob do
      run_migration
    end
    assert_equal "0.8404", @tr_account.reload.raw_positions_payload.first["price"]

    connection.add_column(:trade_republic_items, :device_id, :uuid, default: -> { "gen_random_uuid()" }, null: false)
    connection.add_column(:trade_republic_items, :session_expires_at, :datetime)
    # Deliberately keep the migration process's stale model cache.
    assert_enqueued_jobs 1, only: SyncJob do
      run_refresh
    end
    assert @item.reload.ready_for_sync?
    assert @item.device_id.present?
    assert_no_difference -> { @item.syncs.count } do
      run_refresh
    end
  end

  test "refresh continues after an item cannot enqueue its sync" do
    failed_item = mock("item whose queue is unavailable")
    failed_item.stubs(:id).returns(@item.id)
    failed_item.expects(:sync_later).raises(RuntimeError, "queue down")
    next_item = mock("next eligible item")
    next_item.expects(:sync_later).once
    items = mock("eligible linked items")
    items.expects(:find_each).multiple_yields([ failed_item ], [ next_item ])
    TradeRepublicItem.stubs(:syncable).returns(items)
    items.stubs(:where).returns(items)

    migration = RefreshTradeRepublicBalancesAfterBondRescale.new
    migration.expects(:say).with(regexp_matches(/Could not schedule a sync.*queue down/))
    migration.up
  end

  test "refresh skips expired and disconnected items and unlinked portfolios" do
    @item.update_columns(session_expires_at: 1.hour.ago)
    assert_no_enqueued_jobs only: SyncJob do
      run_refresh
    end
    @item.update_columns(session_expires_at: nil, status: "requires_update")
    assert_no_enqueued_jobs only: SyncJob do
      run_refresh
    end
    @item.update_columns(status: "good", scheduled_for_deletion: true)
    assert_no_enqueued_jobs only: SyncJob do
      run_refresh
    end
    @item.update_columns(scheduled_for_deletion: false)
    @tr_account.account_provider.destroy!
    assert_no_enqueued_jobs only: SyncJob do
      run_refresh
    end
  end

  private

    def create_snapshot(isin, date, qty:, price:, cost_basis:, **attributes)
      security = attributes.delete(:security) || Security.find_or_create_by!(ticker: isin) { |s| s.name = isin }
      @account.holdings.create!({
        security: security,
        date: date,
        qty: BigDecimal(qty),
        price: BigDecimal(price),
        amount: BigDecimal(qty) * BigDecimal(price),
        cost_basis: cost_basis && BigDecimal(cost_basis),
        currency: "EUR",
        external_id: "trade_republic_position_DEBOND1_#{isin}_#{date}",
        account_provider_id: @tr_account.account_provider.id
      }.merge(attributes))
    end

    def run_refresh
      ActiveRecord::Migration.suppress_messages do
        RefreshTradeRepublicBalancesAfterBondRescale.new.up
      end
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        RescaleTradeRepublicBondHoldingPrices.new.up
      end
    end
end

# Exercise the real after-commit enqueue boundary without a fixture transaction.
class TradeRepublicBalanceRefreshEnqueueTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  self.fixture_table_names = []

  Item = Struct.new(:id) do
    def sync_later
      ActiveRecord::Base.transaction { SyncJob.perform_later(id) }
    end
  end

  test "an after-commit queue failure does not abort the migration or skip later items" do
    items = mock("eligible linked items")
    TradeRepublicItem.stubs(:syncable).returns(items)
    items.stubs(:where).returns(items)
    items.expects(:find_each).multiple_yields([ Item.new("failed") ], [ Item.new("next") ])
    SyncJob.queue_adapter.expects(:enqueue).with { |job| job.arguments == [ "failed" ] }.raises(RuntimeError, "queue down")
    SyncJob.queue_adapter.expects(:enqueue).with { |job| job.arguments == [ "next" ] }.once

    migration = RefreshTradeRepublicBalancesAfterBondRescale.new
    migration.expects(:say).with(regexp_matches(/Could not schedule a sync.*queue down/))
    # Use Rails' transaction wrapper, not just migration.up: the error otherwise
    # happens after up has returned, outside its per-item rescue.
    migrator = ActiveRecord::Migrator.allocate
    migrator.stubs(:connection).returns(ActiveRecord::Base.connection)
    migrator.send(:ddl_transaction, migration) { migration.up }
  end
end
