require "test_helper"

class HoldingLotDisposalTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include SqlQueryCapture

  TODAY = Time.zone.local(2024, 6, 10, 12)

  # --- The book ---------------------------------------------------------------

  test "under fifo the book consumes the oldest lot first and records what each sale took" do
    book = Holding::LotBook.new(method: "fifo")
    book.apply(BigDecimal("12"), 60, source_id: "first")
    book.apply(BigDecimal("20"), 40, source_id: "second")

    book.apply(BigDecimal("25"), -70, source_id: "sale")

    assert_equal [ [ "sale", "first", 60, 12 ], [ "sale", "second", 10, 20 ] ],
      book.disposals.map { |d| [ d.sale_id, d.lot_source_id, d.qty, d.unit_cost ] }
    assert_equal [ [ "second", 30 ] ], book.lots.map { |lot| [ lot.source_id, lot.qty ] }
    assert_equal 20, book.average_cost
  end

  test "under fifo a sale beyond the open lots records the excess at an unknown cost" do
    book = Holding::LotBook.new(method: "fifo")
    book.apply(BigDecimal("12"), 5, source_id: "buy")

    book.apply(nil, -8, source_id: "sale")

    assert_equal [ [ "buy", 5, 12 ], [ nil, 3, nil ] ], book.disposals.map { |d| [ d.lot_source_id, d.qty, d.unit_cost ] }
    assert_equal 0, book.open_qty
  end

  test "under average the book records no disposals" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("12"), 60, source_id: "first")
    book.apply(BigDecimal("20"), 40, source_id: "second")

    book.apply(BigDecimal("25"), -40, source_id: "sale")

    assert_empty book.disposals
    assert_equal BigDecimal("15.2"), book.average_cost
  end

  test "under fifo a consumed transfer-in lot no longer makes the cost unknown" do
    fifo = Holding::LotBook.new(method: "fifo")
    fifo.add_unknown(10, source_id: "transfer")
    fifo.apply(BigDecimal("12"), 10, source_id: "buy")
    assert fifo.unknown_cost?

    fifo.apply(BigDecimal("30"), -10, source_id: "sale")

    assert_not fifo.unknown_cost?
    assert_equal 12, fifo.average_cost
  end

  test "a transfer-in sold under fifo leaves the remaining position's basis known, forward and reverse" do
    travel_to TODAY do
      %i[forward reverse].each do |strategy|
        figures = %w[average fifo].map do |method|
          setup_account(method: method)
          security = priced_security("FIFT#{strategy.to_s[0]}#{method[0]}", 30)
          trade(security, 10, 30, 2).entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
          trade(security, 10, 12, 3)
          trade(security, -10, 30, 5)
          if strategy == :reverse
            link_account
            @account.holdings.create!(security: security, date: d(10), qty: 10, price: 30, amount: 300, currency: "USD", account_provider: @account_provider)
          end
          materialize(strategy)
          @account.holdings.find_by!(security: security, date: d(9)).cost_basis
        end

        assert_equal [ nil, 12 ], figures, "#{strategy}: average stays unknown until the position closes"
      end
    end
  end

  # --- The Example from the lot cost basis proposal ---------------------------
  # 60 bought at $12, 40 at $20; 40 sold at $25.

  test "fifo consumes the oldest lot first" do
    travel_to TODAY do
      average = example(method: "average")
      fifo = example(method: "fifo")

      assert_equal [ 392, BigDecimal("15.2") ], average
      assert_equal 520, fifo.first, "basis 40 x $12 = $480"
      assert_in_delta BigDecimal("17.3333"), fifo.last, BigDecimal("0.0001")
    end
  end

  test "fifo sale crossing two lots" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("FIFB", 30)
      trade(security, 60, 12, 2)
      trade(security, 40, 20, 3)
      sale = trade(security, -70, 25, 6)
      materialize(:forward)

      assert_equal 1750 - 920, gain(sale), "60 x $12 + 10 x $20 = $920"
      assert_equal 920, HoldingLotDisposal.where(sale_entry: sale).sum("qty * unit_cost")
    end
  end

  test "average account figures unchanged after the method column exists" do
    travel_to TODAY do
      setup_account
      assert_equal "average", @account.cost_basis_method

      assert_no_difference "HoldingLotDisposal.count" do
        assert_equal [ 392, BigDecimal("15.2") ], example_on_account
      end
    end
  end

  test "realized gain reads the persisted consumption, not the post-sale snapshot" do
    travel_to TODAY do
      setup_account(method: "fifo")
      sale = example_trades
      materialize(:forward)
      snapshot_basis = @account.holdings.find_by!(security: @security, date: d(6)).avg_cost.amount * 40

      assert_in_delta 1000 - snapshot_basis, BigDecimal("306.67"), BigDecimal("0.01"), "the snapshot holds what remains"
      assert_equal 520, gain(sale)
    end
  end

  test "foreign-currency lot: basis at acquisition-date rate, proceeds at sale-date rate" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("FIFE", 30)
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: d(2), rate: 1.5)
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: d(6), rate: 2)
      create_trade(security, account: @account, qty: 10, price: 100, date: d(2), currency: "EUR")
      sale = create_trade(security, account: @account, qty: -10, price: 130, date: d(6), currency: "EUR")
      materialize(:forward)

      assert_equal Money.new(1500, "USD"), HoldingLotDisposal.find_by!(sale_entry: sale).then { |d| Money.new(d.qty * d.unit_cost, d.currency) }
      assert_equal 2600 - 1500, gain(sale), "not 2600 - 2000, the basis at the sale-date rate"
    end
  end

  test "missing sale-date rate still reports :missing_exchange_rate" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("FIFM", 30)
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: d(2), rate: 1.5)
      create_trade(security, account: @account, qty: 10, price: 100, date: d(2), currency: "EUR")
      sale = create_trade(security, account: @account, qty: -10, price: 130, date: d(6), currency: "EUR")
      materialize(:forward)
      assert HoldingLotDisposal.exists?(sale_entry: sale), "the lot side is known"

      trade = Trade.find(sale.entryable_id)
      assert_nil trade.realized_gain_loss
    end
  end

  test "a sale that consumes the opening lot has an unknown basis" do
    travel_to TODAY do
      build_reverse_fixture(pre_history: 2)
      materialize(:reverse)

      trade = Trade.find(@sale.entryable_id)
      assert_nil trade.realized_gain_loss
      assert_equal [ [ nil, 2 ], [ @first.id, 2 ] ],
        HoldingLotDisposal.where(sale_entry: @sale).map { |d| [ d.lot_source_entry_id, d.qty ] }.sort_by { |id, _| id.to_s }
    end
  end

  test "a materialization scoped to one security restates only that security's disposals" do
    travel_to TODAY do
      setup_account(method: "fifo")
      kept, restated = priced_security("FIFK", 30), priced_security("FIFS", 30)
      [ kept, restated ].each { |security| trade(security, 10, 12, 2) }
      kept_sale = trade(kept, -4, 25, 5)
      restated_sale = trade(restated, -4, 25, 5)
      materialize(:forward)
      kept_ids = HoldingLotDisposal.where(sale_entry: kept_sale).pluck(:id)

      restated_sale.entryable.update!(qty: -6)
      Holding::Materializer.new(@account.reload, strategy: :forward, security_ids: [ restated.id ]).materialize_holdings

      assert_equal kept_ids, HoldingLotDisposal.where(sale_entry: kept_sale).pluck(:id)
      assert_equal [ 6 ], HoldingLotDisposal.where(sale_entry: restated_sale).pluck(:qty)
    end
  end

  # --- The partition guard ----------------------------------------------------

  test "unlink, forward sync, then read: lots out of partition fall back to the snapshot figure" do
    travel_to TODAY do
      # 6 units before the trades: the sale takes 4 of them, and 2 stay open.
      build_reverse_fixture(pre_history: 6)
      materialize(:reverse)
      assert_nil Trade.find(@sale.entryable_id).realized_gain_loss
      @account_provider.destroy!
      materialize(:forward)

      assert_equal 16, @account.holdings.find_by!(security: @security, date: d(10)).qty
      assert_equal 18, HoldingLot.where(security: @security).sum(:qty), "the retained opening lot's 2"
      assert_equal 400, HoldingLotDisposal.where(sale_entry: @sale).sum("qty * unit_cost"), "the forward run's record"

      snapshot_basis = @account.holdings.find_by!(security: @security, date: d(5)).avg_cost.amount * 4
      assert_equal 650, snapshot_basis
      assert_equal 4 * 300 - 650, gain(@sale)
    end
  end

  test "lots in partition are read" do
    travel_to TODAY do
      build_reverse_fixture(pre_history: 0)
      materialize(:reverse)

      assert_equal 16, HoldingLot.where(security: @security).sum(:qty)
      assert_equal 650, @account.holdings.find_by!(security: @security, date: d(5)).avg_cost.amount * 4
      assert_equal 4 * 300 - 400, gain(@sale), "the lot record, not the snapshot's $650"
    end
  end

  private
    def d(day)
      Date.new(2024, 6, day)
    end

    def setup_account(method: "average")
      @family = families(:empty)
      @account = @family.accounts.create!(name: "Lots", balance: 20000, cash_balance: 20000, currency: "USD",
        accountable: Investment.new, cost_basis_method: method)
    end

    def link_account
      coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
      @account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)
    end

    def priced_security(ticker, price)
      security = Security.create!(ticker: ticker, name: ticker)
      Security::Price.insert_all((d(1)..d(10)).map { |date| { security_id: security.id, date: date, price: price, currency: "USD" } })
      security
    end

    def trade(security, qty, price, day)
      create_trade(security, account: @account, qty: qty, price: price, date: d(day))
    end

    def example_trades
      @security = priced_security("FIF#{@account.cost_basis_method[0]}", 30)
      trade(@security, 60, 12, 2)
      trade(@security, 40, 20, 4)
      trade(@security, -40, 25, 6)
    end

    # [realized gain of the sale, average cost of what remains]
    def example(method:)
      setup_account(method: method)
      example_on_account
    end

    def example_on_account
      sale = example_trades
      materialize(:forward)
      [ gain(sale), @account.holdings.find_by!(security: @security, date: d(10)).avg_cost.amount ]
    end

    # A linked fifo account holding `pre_history` units from before its first
    # imported trade: 10 bought at $100, 10 at $200, then 4 sold at $300.
    def build_reverse_fixture(pre_history:)
      setup_account(method: "fifo")
      link_account
      @security = priced_security("FIFR", 30)
      @first = trade(@security, 10, 100, 3)
      trade(@security, 10, 200, 4)
      @sale = trade(@security, -4, 300, 5)
      qty = 16 + pre_history
      @account.holdings.create!(security: @security, date: d(10), qty: qty, price: 30, amount: qty * 30, currency: "USD",
        account_provider: @account_provider)
    end

    def materialize(strategy)
      Holding::Materializer.new(@account.reload, strategy: strategy).materialize_holdings
    end

    def gain(entry)
      Trade.find(entry.entryable_id).realized_gain_loss&.value&.amount
    end
end
