require "test_helper"
require "minitest/mock"

class Holding::LotBookTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # Holding::CostBasisTracker exactly as it stood before the lot book, kept here
  # as the oracle: under the average method the lot book must give the same
  # figure at every step, to the last digit.
  class ReferenceTracker
    def initialize
      reset
    end

    def apply(price, qty)
      return if qty.nil?

      qty = qty.to_d
      return if qty.zero?

      qty.positive? ? buy(price, qty) : sell(qty)
    end

    def buy(price, qty)
      qty = qty&.to_d
      return if qty.nil? || !qty.positive?

      @unknown = true if price.nil?
      @total_cost += price.to_d * qty unless price.nil?
      @total_qty += qty
    end

    def sell(qty)
      qty = qty&.to_d
      return if qty.nil? || qty.zero? || @total_qty.zero?

      relieved_qty = [ qty.abs, @total_qty ].min
      @total_cost -= (@total_cost / @total_qty) * relieved_qty
      @total_qty -= relieved_qty

      reset if @total_qty <= 0
    end

    def split(ratio)
      @total_qty = Security::Split.scale(@total_qty, ratio)
    end

    def average_cost
      return nil if @total_qty.zero? || @unknown

      @total_cost / @total_qty
    end

    private
      def reset
        @total_cost = BigDecimal("0")
        @total_qty = BigDecimal("0")
        @unknown = false
      end
  end

  # The oracle behind the calculators' calls: the lot arguments are ignored and
  # a transfer-in is a no-op, which is what the calculators did before lots.
  class ReferenceCalculatorTracker < ReferenceTracker
    def apply(price, qty, **)
      super(price, qty)
    end

    def add_unknown(*, **); end
  end

  THIRD = BigDecimal("10") / 3

  SEQUENCES = {
    "buys, partial sells, full liquidation and a repurchase" => [
      [ :buy, 100, 10 ], [ :buy, 200, 10 ], [ :sell, 5 ], [ :buy, 150, 3 ], [ :sell, 18 ], [ :buy, 50, 2 ]
    ],
    "the two-parcel example" => [
      [ :buy, 12, 60 ], [ :buy, 20, 40 ], [ :sell, 40 ]
    ],
    "non-terminating relief and splits" => [
      [ :buy, 10, 10 ], [ :buy, BigDecimal("13.37"), 20 ], [ :sell, THIRD ], [ :split, Rational(3, 1) ],
      [ :sell, THIRD ], [ :buy, BigDecimal("7.77"), 1 ], [ :split, Rational(1, 7) ], [ :sell, BigDecimal("0.123") ]
    ],
    "an unknown price and a transfer lot" => [
      [ :buy, 10, 5 ], [ :unknown, 4 ], [ :buy, nil, 2 ], [ :sell, 3 ], [ :buy, 9, 3 ],
      [ :unknown, 2 ], [ :sell, 1 ]
    ]
  }.freeze

  SEQUENCES.each do |name, steps|
    test "lot book under average reproduces the tracker: #{name}" do
      book = Holding::LotBook.new
      reference = ReferenceTracker.new

      steps.each_with_index do |(op, *args), index|
        case op
        when :buy
          book.apply(args[0]&.to_d, args[1], source_id: index, acquired_on: Date.new(2024, 1, 1) + index)
          reference.apply(args[0]&.to_d, args[1])
        when :sell
          book.apply(nil, -args[0])
          reference.apply(nil, -args[0])
        when :split
          book.split(args[0])
          reference.split(args[0])
        when :unknown
          # A transfer-in never reached the tracker.
          book.add_unknown(args[0], source_id: index, acquired_on: Date.new(2024, 1, 1) + index)
        end

        if reference.average_cost.nil?
          assert_nil book.average_cost, "step #{index} (#{op})"
        else
          assert_equal reference.average_cost, book.average_cost, "step #{index} (#{op})"
        end
      end
    end
  end

  test "each acquisition is one lot, keyed by its source entry, and a later buy leaves earlier lots alone" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("12"), 60, source_id: "buy-1", acquired_on: Date.new(2024, 1, 10))
    first = book.lots.first

    book.apply(BigDecimal("20"), 40, source_id: "buy-2", acquired_on: Date.new(2024, 3, 5))

    assert_equal %w[buy-1 buy-2], book.lots.map(&:source_id)
    assert_equal [ Date.new(2024, 1, 10), Date.new(2024, 3, 5) ], book.lots.map(&:acquired_on)
    assert_equal first, book.lots.first, "the earlier lot is untouched by the later buy"
    assert_equal [ 12, 20 ], book.lots.map(&:unit_cost)
  end

  test "a sale under average relieves every lot pro rata and keeps each lot's own cost" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("12"), 60, source_id: "a")
    book.apply(BigDecimal("20"), 40, source_id: "b")

    book.apply(nil, -40)

    assert_equal [ 36, 24 ], book.lots.map(&:qty)
    assert_equal [ 12, 20 ], book.lots.map(&:unit_cost)
    assert_equal BigDecimal("15.2"), book.average_cost
    assert_equal book.average_cost, lots_weighted_mean(book)
  end

  test "a split restates every lot: more units at a lower cost, same money" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("12"), 60, source_id: "a")
    book.apply(BigDecimal("20"), 40, source_id: "b")

    book.split(Rational(2, 1))

    assert_equal [ 120, 80 ], book.lots.map(&:qty)
    assert_equal [ 6, 10 ], book.lots.map(&:unit_cost)
    assert_equal BigDecimal("7.6"), book.average_cost
  end

  test "a transfer-in is a lot of unknown cost and does not move the average" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("20"), 40, source_id: "buy")
    book.add_unknown(60, source_id: "transfer", acquired_on: Date.new(2024, 1, 10))

    assert_equal [ nil ], book.lots.select { |lot| lot.source_id == "transfer" }.map(&:unit_cost)
    assert_equal 100, book.open_qty
    assert_equal 20, book.average_cost, "the calculators, not the pool, report the position as unknown"
  end

  test "the lots' weighted mean matches the average to within rounding of a non-terminating relief" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("10"), 10, source_id: "a")
    book.apply(BigDecimal("13.37"), 20, source_id: "b")
    book.apply(nil, -THIRD)
    book.split(Rational(3, 1))
    book.apply(nil, -THIRD)

    assert_in_delta book.average_cost, lots_weighted_mean(book), BigDecimal("1e-12")
  end

  test "sum of open lot qty equals the running position after every step" do
    book = Holding::LotBook.new
    position = BigDecimal("0")
    steps = [
      [ :buy, 10, 10 ], [ :buy, 12, 5 ], [ :unknown, 4 ], [ :sell, 7 ], [ :split, Rational(2, 1) ],
      [ :sell, THIRD ], [ :split, Rational(1, 3) ], [ :sell, 3 ], [ :buy, 9, 2 ]
    ]

    steps.each_with_index do |(op, *args), index|
      case op
      when :buy
        book.apply(args[0].to_d, args[1], source_id: index)
        position += args[1]
      when :unknown
        book.add_unknown(args[0], source_id: index)
        position += args[0]
      when :sell
        book.apply(nil, -args[0])
        position -= args[0]
      when :split
        book.split(args[0])
        position = Security::Split.scale(position, args[0])
      end

      assert_equal position, book.open_qty, "step #{index} (#{op})"
      assert_equal position, book.lots.sum(BigDecimal("0"), &:qty), "step #{index} (#{op})"
    end
  end

  test "selling out closes every lot, a transfer lot included" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("10"), 10, source_id: "a")
    book.add_unknown(5, source_id: "t")

    book.apply(nil, -15)

    assert_empty book.lots
    assert_equal 0, book.open_qty
  end

  # The pool never held the transferred units, so this sale empties it and it
  # resets. The position still holds 5 units, and the lots must still say so.
  test "a sale that empties the priced pool leaves every lot's share of what is still held" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("10"), 10, source_id: "buy")
    book.add_unknown(5, source_id: "transfer")

    book.apply(nil, -10)

    assert_nil book.average_cost
    assert_equal 5, book.open_qty
    assert_equal %w[buy transfer], book.lots.map(&:source_id)
  end

  test "the tracker keeps its public interface" do
    tracker = Holding::CostBasisTracker.new
    tracker.apply(BigDecimal("100"), BigDecimal("10"))
    tracker.buy(BigDecimal("200"), BigDecimal("10"))
    tracker.sell(BigDecimal("-5"))
    tracker.split(Rational(2, 1))

    assert_equal BigDecimal("75"), tracker.average_cost
  end

  # --- Through the calculators and the materializer -------------------------

  test "materialize writes identical holdings with lots on the forward strategy" do
    travel_to Time.zone.local(2024, 6, 10, 12) do
      build_forward_fixture

      reference = dump_after(:forward, reference: true) { seed_locked_row }
      actual = dump_after(:forward, reference: false) { seed_locked_row }

      assert_equal reference, actual
      assert_fixture_not_vacuous(actual)
    end
  end

  test "materialize writes identical holdings with lots on the reverse strategy" do
    travel_to Time.zone.local(2024, 6, 10, 12) do
      build_reverse_fixture

      reference = dump_after(:reverse, reference: true) { seed_provider_rows }
      actual = dump_after(:reverse, reference: false) { seed_provider_rows }

      assert_equal reference, actual
      assert_fixture_not_vacuous(actual)
      assert(actual.any? { |row| row[4] == "provider" }, "a provider-only position is in the dump")
    end
  end

  test "locked manual row keeps its value through re-materialization with lots present" do
    travel_to Time.zone.local(2024, 6, 10, 12) do
      build_forward_fixture
      seed_locked_row
      locked = @account.holdings.find_by!(security: @parcels, date: d(5))

      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

      locked.reload
      assert_equal 99, locked.cost_basis
      assert_equal "manual", locked.cost_basis_source
      assert locked.cost_basis_locked
      assert_equal BigDecimal("15.2"), @account.holdings.find_by!(security: @parcels, date: d(4)).cost_basis,
        "the neighbouring unlocked row still takes the calculated figure"
    end
  end

  test "transfer-in leaves the position unknown while its lot is held, and known once sold out" do
    travel_to Time.zone.local(2024, 6, 10, 12) do
      build_forward_fixture

      calculator = Holding::ForwardCalculator.new(@account)
      calculator.calculate
      transfer_entry = @account.entries.find_by!(name: "Transfer in")

      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

      assert_nil cost_basis_on(@transferred, d(3)), "the transfer lot is held"
      assert_nil cost_basis_on(@transferred, d(4))
      assert_equal 15, cost_basis_on(@transferred, d(7)), "sold out on d5, then bought back at 15"
      rebuy = @account.entries.find_by!(date: d(7), entryable_type: "Trade", entryable_id: Trade.where(security: @transferred).select(:id))
      lots = calculator.instance_variable_get(:@lot_books)[@transferred.id].lots
      assert_equal [ [ rebuy.id, d(7), 8, 15 ] ], lots.map { |lot| [ lot.source_id, lot.acquired_on, lot.qty, lot.unit_cost ] },
        "the transfer lot and the first buy closed with the sell-out; only the rebuy is open"
      assert_not_includes lots.map(&:source_id), transfer_entry.id
    end
  end

  test "the reverse calculator books a lot per acquisition, a transfer-in included" do
    travel_to Time.zone.local(2024, 6, 10, 12) do
      build_reverse_fixture
      seed_provider_rows
      transfer, buy = @account.entries.where(entryable_id: Trade.where(security: @gapped).select(:id)).order(:date).to_a

      calculator = Holding::ReverseCalculator.new(@account, portfolio_snapshot: Holding::PortfolioSnapshot.new(@account))
      calculator.calculate

      lots = calculator.instance_variable_get(:@lot_books)[@gapped.id].lots
      assert_equal [ [ transfer.id, d(2), 5, nil ], [ buy.id, d(4), 5, 150 ] ],
        lots.map { |lot| [ lot.source_id, lot.acquired_on, lot.qty, lot.unit_cost ] }
    end
  end

  test "sum of open lot qty equals the trade-driven position on every date" do
    travel_to Time.zone.local(2024, 6, 10, 12) do
      build_forward_fixture
      probe = PartitionProbe.new(@account, security_ids: [ @parcels.id, @transferred.id, @split.id ])

      probe.calculate

      assert_equal (d(1)..d(10)).count * 3, probe.checks.size, "every date for each of the three positions"
      probe.checks.each do |date, security_id, position, open_qty|
        assert_equal position.to_d, open_qty, "#{Security.find(security_id).ticker} on #{date}"
      end
      # Every movement kind is crossed: buy, sell, transfer, split.
      assert(probe.checks.any? { |_, id, position, _| id == @split.id && position == 81 }, "after the 3-for-1 split and the sales")
      assert(probe.checks.any? { |_, id, position, _| id == @transferred.id && position == 15 }, "the transfer lot is counted")
    end
  end

  test "selling exactly to zero stays known — the reopen after a clean close is not unknown" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("10"), 5, source_id: "a", acquired_on: Date.new(2024, 1, 1))

    book.apply(nil, -5)
    book.apply(BigDecimal("20"), 1, source_id: "b", acquired_on: Date.new(2024, 2, 1))

    assert_equal BigDecimal("20"), book.average_cost
  end

  test "repeated partial relief keeps lot quantities at the trade scale and the open sum exact" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("1"), 1, source_id: "a", acquired_on: Date.new(2024, 1, 1))
    book.apply(BigDecimal("1"), 2, source_id: "b", acquired_on: Date.new(2024, 1, 2))

    # Five halves of the open position: the first relief divides by three, so
    # every lot quantity is a non-terminating decimal from there on.
    5.times { book.apply(nil, -BigDecimal("0.5")) }

    assert_equal BigDecimal("0.5"), book.open_qty, "the last-lot drift correction keeps the open sum exact"
    book.lots.each do |lot|
      decimals = lot.qty.to_s("F").split(".").last.to_s.length
      assert_operator decimals, :<=, Security::Split::QTY_SCALE,
        "lot #{lot.source_id} has #{decimals} decimal places after five partial sells"
    end
  end

  test "an uncovered sale leaves a shortfall that the next acquisition fills before any lot opens" do
    book = Holding::LotBook.new
    book.apply(BigDecimal("10"), 5, source_id: "a", acquired_on: Date.new(2024, 1, 1))

    book.apply(nil, -100)
    assert_empty book.lots, "the ledger closes what it can"

    book.apply(BigDecimal("12"), 3, source_id: "tiny", acquired_on: Date.new(2024, 2, 1))
    assert_empty book.lots, "3 of the 95 missing units are absorbed, not opened"

    book.apply(BigDecimal("12"), 100, source_id: "fill", acquired_on: Date.new(2024, 3, 1))
    assert_equal [ BigDecimal("8") ], book.lots.map(&:qty), "only the remainder opens a lot: 100 minus the 92 still missing"
    assert_equal BigDecimal("8"), book.open_qty
    assert_equal %w[fill], book.lots.map(&:source_id)
    assert_equal BigDecimal("12"), book.average_cost, "the filled units carry the filling trade's cost"
  end

  class PartitionProbe < Holding::ForwardCalculator
    def checks
      @checks ||= []
    end

    private
      def build_holdings(portfolio, date, price_source: nil)
        portfolio.each do |security_id, qty|
          next unless @security_ids.include?(security_id)

          checks << [ date, security_id, qty, @lot_books[security_id].open_qty ]
        end
        super
      end
  end

  private
    def d(day)
      Date.new(2024, 6, day)
    end

    def lots_weighted_mean(book)
      book.lots.sum { |lot| lot.qty * lot.unit_cost } / book.open_qty
    end

    def setup_account
      @family = families(:empty)
      @account = @family.accounts.create!(name: "Lots", balance: 20000, cash_balance: 20000, currency: "USD", accountable: Investment.new)
    end

    def priced_security(ticker, price)
      security = Security.create!(ticker: ticker, name: ticker)
      Security::Price.insert_all((d(1)..d(10)).map { |date| { security_id: security.id, date: date, price: price, currency: "USD" } })
      security
    end

    def trade(security, qty, price, day, label: nil, fee: 0)
      entry = create_trade(security, account: @account, qty: qty, price: price, date: d(day), fee: fee)
      entry.entryable.update!(investment_activity_label: label) if label
      entry
    end

    # Four positions on one forward account: the two-parcel example, a
    # transfer-in that is sold out and bought back, a negative position a
    # transfer brings back to zero, and a 3-for-1 split with non-terminating
    # sales and a fee.
    def build_forward_fixture
      setup_account
      @parcels = priced_security("LOTA", 30)
      @transferred = priced_security("LOTB", 30)
      @negative = priced_security("LOTC", 30)
      @split = priced_security("LOTD", 30)

      trade(@parcels, 60, 12, 2)
      trade(@parcels, 40, 20, 4)
      trade(@parcels, -40, 25, 6)

      trade(@transferred, 5, 30, 2, label: Trade::TRANSFER_LABEL).update!(name: "Transfer in")
      trade(@transferred, 10, 10, 3)
      trade(@transferred, -15, 30, 5)
      trade(@transferred, 8, 15, 7)

      trade(@negative, -5, 30, 2)
      trade(@negative, 5, 30, 3, label: Trade::TRANSFER_LABEL)
      trade(@negative, 10, 10, 4)
      trade(@negative, -10, 30, 6)
      trade(@negative, 10, 20, 8)

      trade(@split, 10, 10, 2)
      trade(@split, 20, BigDecimal("13.37"), 3)
      Security::Split.create!(security: @split, ex_date: d(4), numerator: 3, denominator: 1, source: "manual")
      trade(@split, -6, 30, 5)
      trade(@split, -3, 30, 6)
      trade(@split, 1, BigDecimal("7.77"), 7, fee: BigDecimal("1.5"))
    end

    def seed_locked_row
      @account.holdings.create!(
        security: @parcels, date: d(5), qty: 100, price: 30, amount: 3000, currency: "USD",
        cost_basis: 99, cost_basis_source: "manual", cost_basis_locked: true
      )
    end

    # A linked account: a provider-only position with no trades, a position
    # with units held before its first imported trade, and a gapped import
    # whose trades net to more than the provider reports.
    def build_reverse_fixture
      setup_account
      @provider_only = priced_security("LOTE", 30)
      @opening = priced_security("LOTF", 30)
      @gapped = priced_security("LOTG", 30)

      trade(@opening, 10, 100, 3)
      trade(@opening, -4, 30, 5)
      trade(@opening, 2, 110, 7)

      trade(@gapped, 5, 30, 2, label: Trade::TRANSFER_LABEL)
      trade(@gapped, 5, 150, 4)

      coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
      @account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)
    end

    def seed_provider_rows
      { @provider_only => [ 10, 50 ], @opening => [ 10, nil ], @gapped => [ 3, nil ] }.each do |security, (qty, basis)|
        @account.holdings.create!(
          security: security, date: d(10), qty: qty, price: 30, amount: qty * 30, currency: "USD",
          cost_basis: basis, cost_basis_source: basis && "provider", account_provider: @account_provider
        )
      end
    end

    # Materializes from an empty holdings table, so a figure left by an earlier
    # run cannot stand in for one this run failed to write.
    def dump_after(strategy, reference:)
      @account.holdings.delete_all
      yield

      run = -> { Holding::Materializer.new(@account.reload, strategy: strategy).materialize_holdings }
      if reference
        Holding::LotBook.stub(:new, -> { ReferenceCalculatorTracker.new }) { run.call }
      else
        run.call
      end

      @account.holdings.order(:security_id, :date, :currency)
        .pluck(:date, :security_id, :qty, :cost_basis, :cost_basis_source, :cost_basis_locked, :currency)
    end

    def assert_fixture_not_vacuous(rows)
      assert_operator rows.size, :>, 20
      assert(rows.any? { |row| row[3].nil? }, "some rows are unknown")
      assert(rows.any? { |row| row[3].present? && row[4] == "calculated" }, "some rows are calculated")
    end

    def cost_basis_on(security, date)
      @account.holdings.find_by!(security: security, date: date).cost_basis
    end
end
