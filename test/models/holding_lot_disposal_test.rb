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

  # --- A named lot ------------------------------------------------------------

  test "under fifo a sale naming a lot consumes it first, then the oldest" do
    book = Holding::LotBook.new(method: "fifo")
    book.apply(BigDecimal("12"), 60, source_id: "first")
    book.apply(BigDecimal("20"), 40, source_id: "second")

    book.apply(BigDecimal("25"), -70, source_id: "sale", lot_source_id: "second")

    assert_equal [ [ "second", 40, 20 ], [ "first", 30, 12 ] ], book.disposals.map { |d| [ d.lot_source_id, d.qty, d.unit_cost ] }
    assert_equal [ [ "first", 30 ] ], book.lots.map { |lot| [ lot.source_id, lot.qty ] }
  end

  test "what is left of a named lot keeps its place, so the next sale still takes the oldest" do
    book = Holding::LotBook.new(method: "fifo")
    book.apply(BigDecimal("12"), 60, source_id: "first")
    book.apply(BigDecimal("20"), 40, source_id: "second")
    book.apply(BigDecimal("25"), -10, source_id: "named", lot_source_id: "second")

    book.apply(BigDecimal("25"), -10, source_id: "unnamed")

    assert_equal [ [ "named", "second" ], [ "unnamed", "first" ] ], book.disposals.map { |d| [ d.sale_id, d.lot_source_id ] }
    assert_equal [ [ "first", 50 ], [ "second", 30 ] ], book.lots.map { |lot| [ lot.source_id, lot.qty ] }
  end

  test "under average a named lot is ignored" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("12"), 60, source_id: "first")
    book.apply(BigDecimal("20"), 40, source_id: "second")

    book.apply(BigDecimal("25"), -40, source_id: "sale", lot_source_id: "second")

    assert_equal [ [ "first", 36 ], [ "second", 24 ] ], book.lots.map { |lot| [ lot.source_id, lot.qty ] }
    assert_equal BigDecimal("15.2"), book.average_cost
  end

  test "naming the $20 lot realizes $200 and leaves $12 avg, forward and reverse" do
    travel_to TODAY do
      %i[forward reverse].each do |strategy|
        setup_account(method: "fifo")
        @security = priced_security("NAM#{strategy.to_s[0]}", 30)
        trade(@security, 60, 12, 2)
        twenty = trade(@security, 40, 20, 4)
        sale = trade(@security, -40, 25, 6)
        if strategy == :reverse
          link_account
          @account.holdings.create!(security: @security, date: d(10), qty: 60, price: 30, amount: 1800, currency: "USD",
            account_provider: @account_provider)
        end
        materialize(strategy)
        assert_equal 520, gain(sale), "#{strategy}: oldest first without a name"

        name_lot(sale, twenty)
        materialize(strategy)

        assert_equal 200, gain(sale), strategy
        assert_equal 12, @account.holdings.find_by!(security: @security, date: d(9)).cost_basis, strategy
      end
    end
  end

  test "naming a lot larger than its open qty consumes the rest by the account method" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMR", 30)
      trade(security, 60, 12, 2)
      twenty = trade(security, 40, 20, 4)
      sale = trade(security, -70, 25, 6)
      name_lot(sale, twenty)
      materialize(:forward)

      assert_equal 1750 - 1160, gain(sale), "40 x $20 named, then 30 x $12 oldest = $1,160"
      assert_equal 12, @account.holdings.find_by!(security: security, date: d(10)).avg_cost.amount
    end
  end

  test "a named lot that is no longer open falls back to oldest first" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMC", 30)
      trade(security, 60, 12, 2)
      twenty = trade(security, 40, 20, 4)
      name_lot(trade(security, -40, 25, 5), twenty)
      later = trade(security, -20, 25, 6)
      name_lot(later, twenty)
      materialize(:forward)

      assert_equal 500 - 240, gain(later), "the $20 lot is gone, so 20 x $12"
    end
  end

  test "an average account ignores a named lot" do
    travel_to TODAY do
      setup_account
      sale = example_trades
      twenty = @account.entries.find_by!(date: d(4))
      Trade.find(sale.entryable_id).update_columns(lot_source_entry_id: twenty.id)

      assert_no_difference "HoldingLotDisposal.count" do
        materialize(:forward)
      end
      assert_equal [ 392, BigDecimal("15.2") ], [ gain(sale), avg_cost_on(d(10)) ]
    end
  end

  test "naming another account's lot is rejected" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMX", 30)
      sale = trade(security, -10, 25, 6)
      mine = @account
      setup_account(method: "fifo")
      theirs = trade(security, 40, 20, 4)
      sale_trade = Trade.find(sale.entryable_id)

      assert_not sale_trade.update(lot_source_entry: theirs)
      assert sale_trade.errors.of_kind?(:lot_source_entry, :invalid)
      assert_nil sale_trade.reload.lot_source_entry_id
      assert_equal mine, sale.account
    end
  end

  test "a sale can name only an earlier acquisition of its own security, in a fifo account" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMV", 30)
      other_security = priced_security("NAMW", 30)
      earlier = trade(security, 40, 20, 4)
      later = trade(security, 40, 20, 7)
      other = trade(other_security, 40, 20, 4)
      another_sale = trade(security, -1, 25, 5)
      same_day = trade(security, 5, 20, 6)
      sale_entry = trade(security, -10, 25, 6)
      entered_in_order(same_day, sale_entry)
      sale = Trade.find(sale_entry.entryable_id)

      [ later, other, another_sale ].each do |entry|
        assert_not sale.update(lot_source_entry: entry), entry.name
        sale.reload
      end
      assert sale.update(lot_source_entry: same_day), "an acquisition on the sale's own date"
      assert sale.update(lot_source_entry: earlier)
      assert_not Trade.find(earlier.entryable_id).update(lot_source_entry: earlier), "a buy names no lot"
      transfer_out = Trade.find(trade(security, -1, 25, 6).entryable_id)
      transfer_out.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      assert_not transfer_out.update(lot_source_entry: earlier), "a transfer out names no lot"

      sale.update_columns(lot_source_entry_id: nil)
      @account.update!(cost_basis_method: "average")
      assert_not sale.reload.update(lot_source_entry: earlier), "an average account names no lot"
    end
  end

  # The book replays a day's trades in the order they were entered, so a buy
  # entered after the sale on its day is not yet a lot when the sale runs.
  test "a same-day buy is offered only when it was entered before the sale" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMS", 30)
      trade(security, 10, 20, 2)
      before, sale, after = [ [ 5, 22 ], [ -3, 25 ], [ 4, 24 ] ].map { |qty, price| trade(security, qty, price, 6) }
      entered_in_order(before, sale, after)

      choices = Trade.find(sale.entryable_id).lot_choices.to_a
      assert_includes choices, before
      assert_not_includes choices, after
      assert_not Trade.find(sale.entryable_id).update(lot_source_entry: after), "a buy the sale replays before"
    end
  end

  test "a sale's held choice stays offered even once the replay no longer reaches it first" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMU", 30)
      trade(security, 10, 20, 2)
      sale = trade(security, -3, 25, 6)
      after = trade(security, 4, 24, 6)
      entered_in_order(sale, after)
      Trade.where(id: sale.entryable_id).update_all(lot_source_entry_id: after.id)

      assert_includes Trade.find(sale.entryable_id).lot_choices.to_a, after
    end
  end

  test "a named same-day lot entered before the sale is the one it sells from" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMT", 30)
      trade(security, 10, 20, 2)
      same_day = trade(security, 5, 22, 6)
      sale = trade(security, -3, 25, 6)
      entered_in_order(same_day, sale)
      name_lot(sale, same_day)

      materialize(:forward)

      assert_equal [ [ same_day.id, 3 ] ], HoldingLotDisposal.where(sale_entry_id: sale.id).pluck(:lot_source_entry_id, :qty).map { |id, qty| [ id, qty.to_i ] }
    end
  end

  test "editing a sale keeps a choice it already holds, even one it could no longer make" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMK", 30)
      twenty = trade(security, 40, 20, 4)
      sale = trade(security, -10, 25, 6)
      name_lot(sale, twenty)
      @account.update!(cost_basis_method: "average")
      sale_trade = Trade.find(sale.entryable_id)
      assert_empty sale_trade.lot_choices, "an average account offers none"

      assert sale_trade.update(qty: -5, price: 26)
      assert_equal twenty.id, sale_trade.reload.lot_source_entry_id
    end
  end

  # A lot earlier sales emptied cannot be sold from, so it is not offered; a
  # lot the sale itself (or a later one) emptied was still open on its date.
  test "a sale is offered only the lots still open on its date" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMO", 30)
      first = trade(security, 10, 20, 2)
      first_sale = trade(security, -10, 25, 3)
      second = trade(security, 10, 22, 4)
      later_sale = trade(security, -5, 25, 6)
      materialize(:forward)

      assert_equal [ first ], Trade.find(first_sale.entryable_id).lot_choices.to_a, "the lot this sale emptied"
      assert_equal [ second ], Trade.find(later_sale.entryable_id).lot_choices.to_a, "the lot an earlier sale emptied was offered"
      assert_not Trade.find(later_sale.entryable_id).update(lot_source_entry: first), "a sold-out lot can be named by a crafted submit"
    end
  end

  # An opening lot has no acquisition, and an empty one (a clamp records
  # one) must not empty the list with it.
  test "an empty opening lot leaves the sale's choices alone" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMZ", 30)
      buy = trade(security, 10, 20, 2)
      materialize(:forward)
      HoldingLot.create!(account: @account, security: security, origin_security: security, qty: 0, currency: "USD", clamped: true)
      # Entered since the last sync, so no disposal is dated on or after it.
      sale = trade(security, -5, 25, 6)

      assert_equal [ buy ], Trade.find(sale.entryable_id).lot_choices.to_a
    end
  end

  test "a sale's held choice stays offered once its lot is sold out" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMH", 30)
      first = trade(security, 10, 20, 2)
      trade(security, -10, 25, 3)
      second = trade(security, 10, 22, 4)
      later_sale = Trade.find(trade(security, -5, 25, 6).entryable_id)
      later_sale.update_columns(lot_source_entry_id: first.id)
      materialize(:forward)

      assert_equal [ first, second ], later_sale.reload.lot_choices.to_a
    end
  end

  test "deleting the named acquisition clears the choice" do
    travel_to TODAY do
      setup_account(method: "fifo")
      security = priced_security("NAMD", 30)
      twenty = trade(security, 40, 20, 4)
      sale = trade(security, -10, 25, 6)
      name_lot(sale, twenty)

      twenty.destroy!

      assert_nil Trade.find(sale.entryable_id).lot_source_entry_id
    end
  end

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

  # --- The avg-cost fallback on a fifo account --------------------------------

  test "a linked fifo account's current row falls back to the open lots" do
    travel_to TODAY do
      linked_example(method: "average")
      assert_nil current_row.cost_basis
      assert_equal BigDecimal("15.2"), fallback_cost(current_row), "average: the pool, unchanged"

      twenty, sale = linked_example(method: "fifo")
      assert_nil current_row.cost_basis, "the provider gives no cost, so the fallback answers"
      assert_in_delta BigDecimal("17.3333"), fallback_cost(current_row), BigDecimal("0.0001")

      name_lot(sale, twenty)
      materialize(:reverse)
      assert_equal 12, fallback_cost(current_row)
    end
  end

  test "a fifo row the lots cannot describe is unknown, not the pooled average" do
    travel_to TODAY do
      linked_example(method: "fifo")
      earlier = @account.holdings.find_by!(security: @security, date: d(9))
      earlier.update_columns(cost_basis: nil)
      assert_nil fallback_cost(earlier), "an earlier row: the lots are today's"

      lot = HoldingLot.derived.where(account: @account).where("qty > 0").first
      lot.update_columns(qty: lot.qty - 1)
      assert_nil fallback_cost(current_row), "lots out of partition"
    end
  end

  test "a sold-off transfer-in no longer blanks a fifo fallback" do
    travel_to TODAY do
      figures = %w[average fifo].map do |method|
        setup_account(method: method)
        link_account
        @security = priced_security("LFT#{method[0]}", 30)
        trade(@security, 10, 30, 2).entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
        trade(@security, 10, 12, 3)
        trade(@security, -10, 30, 5)
        @account.holdings.create!(security: @security, date: d(10), qty: 10, price: 30, amount: 300, currency: "USD",
          account_provider: @account_provider)
        materialize(:reverse)
        fallback_cost(current_row)
      end

      assert_equal [ nil, 12 ], figures
    end
  end

  test "an open transfer-in lot with no cost leaves the fifo fallback unknown" do
    travel_to TODAY do
      setup_account(method: "fifo")
      link_account
      @security = priced_security("LFU", 30)
      trade(@security, 10, 30, 2).entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      trade(@security, 10, 12, 3)
      @account.holdings.create!(security: @security, date: d(10), qty: 20, price: 30, amount: 600, currency: "USD",
        account_provider: @account_provider)
      materialize(:reverse)

      assert_nil fallback_cost(current_row)
    end
  end

  test "units held before the first trade stay out of the fifo fallback, as they stay out of the book" do
    travel_to TODAY do
      build_reverse_fixture(pre_history: 5)
      materialize(:reverse)
      assert HoldingLot.opening.where(account: @account).sole.qty.positive?, "1 of the 5 is still open"

      assert_equal 150, fallback_cost(current_row)
      assert_equal 150, @account.holdings.find_by!(security: @security, date: d(9)).cost_basis, "the calculators' figure"
    end
  end

  test "a clamped fifo position stays unknown" do
    travel_to TODAY do
      setup_account(method: "fifo")
      link_account
      @security = priced_security("LFK", 30)
      trade(@security, 5, 100, 2)
      trade(@security, 5, 150, 3)
      @account.holdings.create!(security: @security, date: d(10), qty: 3, price: 30, amount: 90, currency: "USD",
        account_provider: @account_provider)
      materialize(:reverse)
      assert HoldingLot.where(account: @account, clamped: true).exists?

      assert_nil fallback_cost(current_row)
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

  test "lots short of the holding fall back to the snapshot figure" do
    travel_to TODAY do
      build_reverse_fixture(pre_history: 0)
      materialize(:reverse)
      lot = HoldingLot.where(security: @security).where("qty >= 2").order(:id).first
      lot.update_columns(qty: lot.qty - 2)

      assert_equal 14, HoldingLot.where(security: @security).sum(:qty), "2 short of the holding's 16"
      assert_equal 4 * 300 - 650, gain(@sale), "the snapshot's $650, not the lot record's $400"
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

    # The clock is frozen, so entries made one after another share a created_at
    # and the replay would order them by id; set the order they were entered.
    def entered_in_order(*entries)
      entries.each_with_index { |entry, index| entry.update_columns(created_at: TODAY + index.seconds) }
    end

    def name_lot(sale, lot)
      Trade.find(sale.entryable_id).update!(lot_source_entry: lot)
    end

    def avg_cost_on(date)
      @account.holdings.find_by!(security: @security, date: date).avg_cost.amount
    end

    # The Example on a linked account whose provider holds the remaining 60
    # and gives no cost for them.
    def linked_example(method:)
      setup_account(method: method)
      link_account
      @security = priced_security("LFX#{method[0]}", 30)
      trade(@security, 60, 12, 2)
      twenty = trade(@security, 40, 20, 4)
      sale = trade(@security, -40, 25, 6)
      @account.holdings.create!(security: @security, date: d(10), qty: 60, price: 30, amount: 1800, currency: "USD",
        account_provider: @account_provider)
      materialize(:reverse)
      [ twenty, sale ]
    end

    def current_row
      @account.holdings.find_by!(security: @security, date: d(10))
    end

    # Holding#avg_cost on a fresh copy, so no earlier answer is reused.
    def fallback_cost(holding)
      Holding.find(holding.id).avg_cost&.amount
    end
end
