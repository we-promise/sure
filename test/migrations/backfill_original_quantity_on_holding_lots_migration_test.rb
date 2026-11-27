require "test_helper"
require Rails.root.join("db/migrate/20261127120001_backfill_original_quantity_on_holding_lots")

class BackfillOriginalQuantityOnHoldingLotsMigrationTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  include EntriesTestHelper

  TODAY = Time.zone.local(2024, 6, 10, 12)

  setup do
    @family = families(:empty)
  end

  test "caps shortfall nil-source disposals at linked baseline across splits (D3-D6 scenario)" do
    travel_to TODAY do
      account = create_account(method: "fifo")
      provider = link_account(account)
      security = priced_security("MGBL")

      buy1 = create_trade(security, account: account, qty: 10, price: 100, date: d(3))
      sale = create_trade(security, account: account, qty: -15, price: 300, date: d(4))
      Security::Split.create!(security: security, ex_date: d(5), numerator: 2, denominator: 1, source: "manual")
      buy2 = create_trade(security, account: account, qty: 6, price: 150, date: d(6))
      account.holdings.create!(security: security, date: d(10), qty: 4, price: 30, amount: 120, currency: "USD",
        account_provider: provider)

      opening_lot = create_opening_lot(account, security, qty: 0, updated_at: TODAY)
      create_disposal(account, sale, nil, 5)
      create_disposal(account, sale, buy1.id, 10)

      run_backfill_up

      opening_lot.reload
      assert_equal 8, opening_lot.original_quantity
      assert_equal d(10), opening_lot.original_quantity_as_of

      provider.destroy!
      Holding::Materializer.new(account.reload, strategy: :forward).materialize_holdings

      assert_equal [ [ nil, 1 ], [ nil, 4 ], [ buy1.id, 10 ] ],
        HoldingLotDisposal.where(sale_entry: sale).order(:id).map { |r| [ r.lot_source_entry_id, r.qty ] }
          .sort_by { |id, qty| [ id.to_s, qty ] }
      assert_equal 4, HoldingLot.find_by!(account: account, source_entry: buy2).qty
    end
  end

  test "excludes shortfall disposals on unlinked 2 + 10 + 10 - 4 - 30 before and after forward sync" do
    travel_to TODAY do
      account = create_account(method: "fifo")
      provider = link_account(account)
      security = priced_security("MGSF")

      trade_buy1 = create_trade(security, account: account, qty: 10, price: 100, date: d(3))
      create_trade(security, account: account, qty: 10, price: 200, date: d(4))
      create_trade(security, account: account, qty: -4, price: 300, date: d(5))
      account.holdings.create!(security: security, date: d(10), qty: 18, price: 30, amount: 540, currency: "USD",
        account_provider: provider)

      Holding::Materializer.new(account.reload, strategy: :reverse).materialize_holdings
      opening_lot = HoldingLot.where(account: account, security: security).opening.sole
      assert_equal 2, opening_lot.original_quantity

      provider.destroy!
      create_trade(security, account: account, qty: -30, price: 300, date: d(6))
      Holding::Materializer.new(account.reload, strategy: :forward).materialize_holdings

      opening_lot.update_columns(original_quantity: nil, original_quantity_as_of: nil)
      run_backfill_up

      assert_equal 2, opening_lot.reload.original_quantity

      Holding::Materializer.new(account.reload, strategy: :forward).materialize_holdings
      assert_equal 2, opening_lot.reload.original_quantity
      assert_equal 0, opening_lot.qty
      assert_equal 0, HoldingLot.find_by!(account: account, source_entry: trade_buy1).qty
    end
  end

  test "does not re-scale splits for linked securities with no trades" do
    travel_to TODAY do
      account = create_account(method: "fifo")
      provider = link_account(account)
      traded = create_security("MGTRD")
      no_trade_2x = create_security("MGNT2")
      no_trade_3x = create_security("MGNT3")
      no_trade_stale_snap = create_security("MGNTS")

      # Establish an account start date before D5 splits.
      create_trade(traded, account: account, qty: 5, price: 50, date: d(1))
      Security::Split.create!(security: no_trade_2x, ex_date: d(5), numerator: 2, denominator: 1, source: "manual")
      Security::Split.create!(security: no_trade_3x, ex_date: d(5), numerator: 3, denominator: 1, source: "manual")
      Security::Split.create!(security: no_trade_stale_snap, ex_date: d(5), numerator: 2, denominator: 1, source: "manual")

      account.holdings.create!(security: no_trade_stale_snap, date: d(3), qty: 5, price: 30, amount: 150, currency: "USD",
        account_provider: provider)
      account.holdings.create!(security: traded, date: d(10), qty: 5, price: 50, amount: 250, currency: "USD",
        account_provider: provider)
      account.holdings.create!(security: no_trade_2x, date: d(10), qty: 10, price: 30, amount: 300, currency: "USD",
        account_provider: provider)
      account.holdings.create!(security: no_trade_3x, date: d(10), qty: 10, price: 30, amount: 300, currency: "USD",
        account_provider: provider)

      lot_2x = create_opening_lot(account, no_trade_2x, qty: 10, updated_at: TODAY)
      lot_3x = create_opening_lot(account, no_trade_3x, qty: 10, updated_at: TODAY)
      lot_stale = create_opening_lot(account, no_trade_stale_snap, qty: 10, updated_at: TODAY)

      run_backfill_up

      assert_equal 10, lot_2x.reload.original_quantity
      assert_equal 10, lot_3x.reload.original_quantity
      assert_equal 10, lot_stale.reload.original_quantity
    end
  end

  test "handles linked average-cost partial relief and subsequent shortfall without under-counting" do
    travel_to TODAY do
      account = create_account(method: "average")
      provider = link_account(account)
      security = create_security("MGAVG")

      buy1 = create_trade(security, account: account, qty: 10, price: 100, date: d(3))
      sale1 = create_trade(security, account: account, qty: -7, price: 300, date: d(4))
      sale2 = create_trade(security, account: account, qty: -10, price: 300, date: d(5))
      create_trade(security, account: account, qty: 8, price: 150, date: d(6))
      account.holdings.create!(security: security, date: d(10), qty: 5, price: 30, amount: 150, currency: "USD",
        account_provider: provider)

      opening_lot = create_opening_lot(account, security, qty: 0, updated_at: TODAY)
      create_disposal(account, sale1, nil, 2)
      create_disposal(account, sale1, buy1.id, 5)
      create_disposal(account, sale2, nil, 5)
      create_disposal(account, sale2, buy1.id, 5)

      run_backfill_up

      opening_lot.reload
      assert_equal 4, opening_lot.original_quantity
      assert_equal d(10), opening_lot.original_quantity_as_of
    end
  end

  test "unlinked backfill uses hl.updated_at as basis_date and ignores later splits" do
    travel_to TODAY do
      account = create_account(method: "fifo")
      security = create_security("MGUL")

      buy1 = create_trade(security, account: account, qty: 10, price: 100, date: d(3))
      sale1 = create_trade(security, account: account, qty: -4, price: 300, date: d(4))
      Security::Split.create!(security: security, ex_date: d(7), numerator: 2, denominator: 1, source: "manual")
      sale2 = create_trade(security, account: account, qty: -30, price: 300, date: d(8))

      opening_before_split = create_opening_lot(account, security, qty: 0, updated_at: d(5))
      create_disposal(account, sale1, nil, 2)
      create_disposal(account, sale1, buy1.id, 2)
      create_disposal(account, sale2, buy1.id, 8)
      create_disposal(account, sale2, nil, 22)

      # Separate security on the same account whose updated_at is after the split:
      # the D7 split scales its consumed opening quantity (2 -> 4) while ignoring the D8 shortfall.
      security_after_split = create_security("MGUL2")
      buy_after = create_trade(security_after_split, account: account, qty: 10, price: 100, date: d(3))
      sale_before = create_trade(security_after_split, account: account, qty: -4, price: 300, date: d(4))
      Security::Split.create!(security: security_after_split, ex_date: d(7), numerator: 2, denominator: 1, source: "manual")
      sale_shortfall = create_trade(security_after_split, account: account, qty: -30, price: 300, date: d(8))

      opening_after_split = create_opening_lot(account, security_after_split, qty: 0, updated_at: TODAY)
      create_disposal(account, sale_before, nil, 2)
      create_disposal(account, sale_before, buy_after.id, 2)
      create_disposal(account, sale_shortfall, buy_after.id, 16)
      create_disposal(account, sale_shortfall, nil, 14)

      run_backfill_up

      opening_before_split.reload
      assert_equal 2, opening_before_split.original_quantity
      assert_equal d(5), opening_before_split.original_quantity_as_of

      opening_after_split.reload
      assert_equal 4, opening_after_split.original_quantity
      assert_equal d(10), opening_after_split.original_quantity_as_of
    end
  end

  test "keeps counting opening disposals after named-lot sales until ordinary FIFO depletion" do
    travel_to TODAY do
      account = create_account(method: "fifo")
      security = create_security("MGNL")

      buy = create_trade(security, account: account, qty: 10, price: 100, date: d(2))
      named_sale = create_trade(security, account: account, qty: -2, price: 300, date: d(3))
      named_sale.entryable.update!(lot_source_entry: buy)
      fifo_sale = create_trade(security, account: account, qty: -7, price: 300, date: d(4))
      shortfall_sale = create_trade(security, account: account, qty: -20, price: 300, date: d(6))

      opening_lot = create_opening_lot(account, security, qty: 0, updated_at: TODAY)
      create_disposal(account, named_sale, buy.id, 2)
      create_disposal(account, fifo_sale, nil, 6)
      create_disposal(account, fifo_sale, buy.id, 1)
      create_disposal(account, shortfall_sale, buy.id, 7)
      create_disposal(account, shortfall_sale, nil, 13)

      run_backfill_up

      assert_equal 6, opening_lot.reload.original_quantity
    end
  end

  test "sets clamped opening lots to zero and preserves already populated or derived rows" do
    travel_to TODAY do
      account = create_account(method: "fifo")
      clamped_security = create_security("MGCL")
      existing_security = create_security("MGEX")
      derived_security = create_security("MGDR")

      sale = create_trade(clamped_security, account: account, qty: -5, price: 300, date: d(4))
      clamped_lot = create_opening_lot(account, clamped_security, qty: 0, clamped: true, updated_at: TODAY)
      create_disposal(account, sale, nil, 5)

      existing_lot = create_opening_lot(account, existing_security, qty: 3, updated_at: TODAY)
      existing_lot.update_columns(original_quantity: 99, original_quantity_as_of: d(3))

      buy = create_trade(derived_security, account: account, qty: 10, price: 100, date: d(2))
      derived_lot = account.holding_lots.create!(
        security: derived_security,
        source_entry: buy,
        qty: 10,
        unit_cost: 100,
        currency: "USD",
        original_quantity: nil,
        original_quantity_as_of: nil
      )

      run_backfill_up

      assert_equal 0, clamped_lot.reload.original_quantity
      assert_equal d(10), clamped_lot.original_quantity_as_of

      assert_equal 99, existing_lot.reload.original_quantity
      assert_equal d(3), existing_lot.original_quantity_as_of

      assert_nil derived_lot.reload.original_quantity
      assert_nil derived_lot.original_quantity_as_of
    end
  end

  test "up and down process all opening lots across multiple small batches and satisfy the check constraint" do
    travel_to TODAY do
      account = create_account(method: "fifo")
      lots = 5.times.map do |idx|
        security = create_security("MGB#{idx}")
        create_opening_lot(account, security, qty: idx, updated_at: TODAY)
      end

      with_batch_size(2) do
        run_backfill_up
      end

      lots.each_with_index do |lot, idx|
        assert_equal idx, lot.reload.original_quantity
        assert_equal d(10), lot.original_quantity_as_of
      end

      assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) do
          lots.first.update_columns(original_quantity: -1)
        end
      end

      with_batch_size(2) do
        run_backfill_down
      end

      lots.each do |lot|
        lot.reload
        assert_nil lot.original_quantity
        assert_nil lot.original_quantity_as_of
      end
    end
  end

  private
    def d(day)
      Date.new(2024, 6, day)
    end

    def create_account(method:)
      @family.accounts.create!(
        name: "Backfill #{method} #{SecureRandom.hex(4)}",
        balance: 20000,
        cash_balance: 20000,
        currency: "USD",
        accountable: Investment.new,
        cost_basis_method: method
      )
    end

    def link_account(account)
      item = @family.coinstats_items.create!(name: "CoinStats #{SecureRandom.hex(3)}", api_key: "test-key")
      provider = item.coinstats_accounts.create!(name: "Provider", currency: "USD")
      AccountProvider.create!(account: account, provider: provider)
    end

    def create_security(ticker)
      Security.create!(ticker: ticker, name: ticker)
    end

    def priced_security(ticker)
      security = create_security(ticker)
      Security::Price.insert_all((d(1)..d(10)).map { |date| { security_id: security.id, date: date, price: 30, currency: "USD" } })
      security
    end

    def create_opening_lot(account, security, qty:, clamped: false, updated_at: TODAY)
      lot = account.holding_lots.create!(
        security: security,
        source_entry: nil,
        qty: qty,
        clamped: clamped,
        unit_cost: nil,
        currency: "USD",
        original_quantity: nil,
        original_quantity_as_of: nil
      )
      lot.update_columns(updated_at: updated_at)
      lot
    end

    def create_disposal(account, sale_entry, lot_source_entry_id, qty)
      HoldingLotDisposal.create!(
        account: account,
        sale_entry: sale_entry,
        lot_source_entry_id: lot_source_entry_id,
        qty: qty,
        unit_cost: nil,
        currency: "USD"
      )
    end

    def run_backfill_up
      ActiveRecord::Migration.suppress_messages { BackfillOriginalQuantityOnHoldingLots.new.up }
    end

    def run_backfill_down
      ActiveRecord::Migration.suppress_messages { BackfillOriginalQuantityOnHoldingLots.new.down }
    end

    def with_batch_size(size)
      original = BackfillOriginalQuantityOnHoldingLots::BATCH_SIZE
      ActiveSupport::Deprecation.new.silence do
        silence_warnings { BackfillOriginalQuantityOnHoldingLots.const_set(:BATCH_SIZE, size) }
      end
      yield
    ensure
      silence_warnings { BackfillOriginalQuantityOnHoldingLots.const_set(:BATCH_SIZE, original) }
    end
end
