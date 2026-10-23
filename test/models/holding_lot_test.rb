require "test_helper"

class HoldingLotTest < ActiveSupport::TestCase
  include EntriesTestHelper

  TODAY = Time.zone.local(2024, 6, 10, 12)
  TWO_THIRDS_UP = BigDecimal("0.666666666666666667")
  TWO_THIRDS_LAST = BigDecimal("0.666666666666666666")

  # --- The book ---------------------------------------------------------------

  test "a sale with nothing held, then a transfer-in, keeps the book's lots equal to the position" do
    book = Holding::LotBook.new

    book.apply(nil, -5)
    book.add_unknown(5, source_id: "transfer")

    assert_equal 0, book.open_qty, "the transfer fills the 5 already sold"

    book.apply(BigDecimal("10"), 10, source_id: "buy")

    assert_equal 10, book.open_qty
    assert_equal [ [ "transfer", 0 ], [ "buy", 10 ] ], book.ledger.map { |lot| [ lot.source_id, lot.qty ] }
  end

  test "a split restates the shortfall with the position" do
    book = Holding::LotBook.new
    book.apply(nil, -6)
    book.split(Rational(2, 1))

    book.add_unknown(12, source_id: "transfer")

    assert_equal 0, book.open_qty, "12 post-split units were already sold"
  end

  test "a pro-rata rounding residual lands on the last open lot of the book" do
    book = Holding::LotBook.new
    %w[a b c].each { |id| book.apply(BigDecimal("10"), 1, source_id: id) }

    book.apply(nil, -1)

    assert_equal [ TWO_THIRDS_UP, TWO_THIRDS_UP, TWO_THIRDS_LAST ], book.lots.map(&:qty)
  end

  # --- Stored lots ------------------------------------------------------------

  test "a buy after lots exist adds one derived lot and leaves the earlier one alone" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTA", 30)
      trade(security, 60, 12, 2)
      materialize(:forward)
      first = HoldingLot.sole

      assert_difference "HoldingLot.count", 1 do
        trade(security, 40, 20, 4)
        materialize(:forward)
      end

      first_after = HoldingLot.find(first.id)
      assert_equal [ 60, 12, d(2) ], [ first_after.qty, first_after.unit_cost, first_after.acquired_on ]
      assert_equal first.created_at, first_after.created_at
      assert_equal [ 40, 20 ], HoldingLot.where.not(id: first.id).pick(:qty, :unit_cost)
    end
  end

  test "a sale with nothing held, then a transfer-in, keeps the stored lots equal to the position" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTC", 30)
      trade(security, -5, 30, 2)
      transfer = trade(security, 5, 30, 3, label: Trade::TRANSFER_LABEL)
      trade(security, 10, 10, 4)

      materialize(:forward)

      assert_equal 10, holding_qty(security, d(10))
      assert_equal 10, HoldingLot.where(security: security).sum(:qty)
      assert_equal 0, HoldingLot.find_by!(source_entry: transfer).qty
    end
  end

  test "a pro-rata rounding residual lands on the last open lot" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTR", 30)
      trade(security, 1, 10, 2)
      trade(security, 1, 10, 3)
      trade(security, 1, 10, 4)
      trade(security, -1, 30, 5)

      materialize(:forward)

      assert_equal [ TWO_THIRDS_UP, TWO_THIRDS_UP, TWO_THIRDS_LAST ],
        HoldingLot.where(security: security).order(:acquired_on).pluck(:qty)
    end
  end

  test "sum of open lot qty equals snapshot qty on every date" do
    setup_account
    @parcels = priced_security("LOTP", 30)
    @split = priced_security("LOTS", 30)
    @moved = priced_security("LOTT", 30)
    trade(@parcels, 60, 12, 2)
    trade(@parcels, 40, 20, 4)
    trade(@parcels, -40, 25, 6)
    trade(@split, 10, 10, 2)
    trade(@split, 20, BigDecimal("13.37"), 3)
    Security::Split.create!(security: @split, ex_date: d(4), numerator: 3, denominator: 1, source: "manual")
    trade(@split, -7, 30, 5)
    trade(@moved, 5, 30, 3, label: Trade::TRANSFER_LABEL)
    trade(@moved, 10, 10, 4)
    trade(@moved, -4, 30, 8)

    (2..10).each do |day|
      travel_to Time.zone.local(2024, 6, day, 12) do
        materialize(:forward)

        [ @parcels, @split, @moved ].each do |security|
          assert_equal holding_qty(security, d(day)), HoldingLot.where(security: security).sum(:qty),
            "#{security.ticker} on #{d(day)}"
        end
      end
    end
    assert_equal 83, holding_qty(@split, d(10)), "the split and a sale are crossed"
  end

  test "sum of open lot qty equals the provider snapshot, opening lot included" do
    travel_to TODAY do
      build_reverse_fixture

      materialize(:reverse)

      { @provider_only => 10, @opening => 10 }.each do |security, provider_qty|
        assert_equal provider_qty, HoldingLot.where(security: security).sum(:qty), security.ticker
        assert_equal 1, HoldingLot.opening.where(security: security).count, security.ticker
      end
    end
  end

  test "provider-only position with no trades keeps its provider basis" do
    travel_to TODAY do
      build_reverse_fixture

      materialize(:reverse)

      holding = @account.holdings.find_by!(security: @provider_only, date: d(10))
      assert_equal [ 50, "provider" ], [ holding.cost_basis, holding.cost_basis_source ]
      lot = HoldingLot.where(security: @provider_only).sole
      assert lot.opening?
      assert_equal [ 10, 50, "USD", false ], [ lot.qty, lot.unit_cost, lot.currency, lot.clamped ]
    end
  end

  # Today the figure averages the imported trades only: 10 @ 100, 4 sold, then
  # 2 @ 110 is (600 + 220) / 8 = 102.5. The 2 units held before the first
  # trade are the opening lot, which the sale relieves pro rata.
  test "the opening lot does not move the calculated figure" do
    travel_to TODAY do
      build_reverse_fixture

      materialize(:reverse)

      assert_equal BigDecimal("102.5"), @account.holdings.find_by!(security: @opening, date: d(8)).cost_basis
      opening = HoldingLot.opening.find_by!(security: @opening)
      assert_equal [ BigDecimal("1.333333333333333333"), nil, @opening.id ], [ opening.qty, opening.unit_cost, opening.origin_security_id ]
      assert_equal 2, HoldingLot.derived.where(security: @opening).count, "one per buy"
    end
  end

  # The trades add up to 10 units and the provider reports 3.
  test "provider quantity below trade-derived quantity clamps the opening lot and records it" do
    travel_to TODAY do
      build_reverse_fixture

      materialize(:reverse)

      clamped = HoldingLot.opening.find_by!(security: @gapped)
      assert_equal [ 0, true ], [ clamped.qty, clamped.clamped ]
      assert_equal 125, @account.holdings.find_by!(security: @gapped, date: d(8)).cost_basis, "the figure is today's"
      assert_equal [ @gapped.id ], HoldingLot.where(clamped: true).pluck(:security_id), "nothing flagged on the controls"
    end
  end

  test "a clamped position that the provider brings back above its trades is unclamped" do
    travel_to TODAY do
      build_reverse_fixture
      materialize(:reverse)
      lot = HoldingLot.opening.find_by!(security: @gapped)
      assert_equal [ 0, true ], [ lot.qty, lot.clamped ]

      @account.holdings.find_by!(security: @gapped, date: d(10)).update!(qty: 12, amount: 360)
      materialize(:reverse)

      lot.reload
      assert_equal [ 2, false ], [ lot.qty, lot.clamped ], "12 reported against 10 traded"
    end
  end

  test "an unclamped position that the provider drops below its trades is clamped" do
    travel_to TODAY do
      build_reverse_fixture
      materialize(:reverse)
      lot = HoldingLot.opening.find_by!(security: @opening)
      assert_equal [ BigDecimal("1.333333333333333333"), false ], [ lot.qty, lot.clamped ]

      @account.holdings.find_by!(security: @opening, date: d(10)).update!(qty: 5, amount: 150)
      materialize(:reverse)

      lot.reload
      assert_equal [ 0, true ], [ lot.qty, lot.clamped ], "5 reported against 8 traded"
    end
  end

  # Unlinking an account turns its syncs forward, and the forward calculator
  # knows nothing of units held before the trades.
  test "a forward sync after unlinking leaves the opening lots alone" do
    travel_to TODAY do
      build_reverse_fixture
      materialize(:reverse)
      opening_ids = HoldingLot.opening.order(:id).pluck(:id)
      assert_equal 3, opening_ids.size

      @account_provider.destroy!
      materialize(:forward)

      assert_equal opening_ids, HoldingLot.opening.order(:id).pluck(:id)
      assert_equal 4, HoldingLot.derived.count, "the derived lots are still the forward path's"
    end
  end

  test "deleting a trade deletes its derived lot" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTD", 30)
      keep = trade(security, 10, 12, 2)
      gone = trade(security, 5, 20, 4)
      materialize(:forward)

      gone.destroy!

      assert_equal [ keep.id ], HoldingLot.pluck(:source_entry_id)
    end
  end

  test "a buy edited into a sale loses its lot on the next materialization" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTE", 30)
      keep = trade(security, 10, 12, 2)
      edited = trade(security, 5, 20, 4)
      materialize(:forward)

      edited.entryable.update!(qty: -5)
      materialize(:forward)

      assert_equal [ keep.id ], HoldingLot.pluck(:source_entry_id)
      assert_equal 5, HoldingLot.sole.qty
    end
  end

  # As SnaptradeAccount::SplitSecurityRepair and the security rake tasks do.
  test "a trade moved to another security without its lot takes the lot along at the next materialization" do
    travel_to TODAY do
      setup_account
      from = priced_security("LOTJ", 30)
      to = priced_security("LOTK", 30)
      entry = trade(from, 10, 12, 2)
      materialize(:forward)
      lot = HoldingLot.sole

      Trade.where(id: entry.entryable_id).update_all(security_id: to.id)
      materialize(:forward)

      assert_equal [ lot.id, to.id ], HoldingLot.sole.then { |moved| [ moved.id, moved.security_id ] }
    end
  end

  # --- Remap and reset --------------------------------------------------------

  test "remap moves lots with their trades" do
    travel_to TODAY do
      setup_account
      old_security = priced_security("LOTO", 30)
      new_security = priced_security("LOTN", 30)
      trade(old_security, 10, 40, 2)
      trade(new_security, 5, 100, 2)
      materialize(:forward)
      ids = HoldingLot.order(:id).pluck(:id)

      @account.holdings.find_by!(security: old_security, date: d(10)).remap_security!(new_security)

      assert_equal [ new_security.id ], HoldingLot.distinct.pluck(:security_id), "moved with the trades, before any sync"

      materialize(:forward, security_ids: [ new_security.id ])

      assert_equal ids, HoldingLot.order(:id).pluck(:id), "re-keyed, not merged or rebuilt"
      assert_equal 60, @account.holdings.find_by!(security: new_security, date: d(10)).cost_basis
    end
  end

  test "reset returns lots to the provider security" do
    travel_to TODAY do
      setup_account
      link_account
      original = priced_security("LOTX", 30)
      replacement = priced_security("LOTY", 30)
      trade(original, 10, 40, 3)
      provider_row = provider_holding(original, 15, nil)
      materialize(:reverse)
      ids = HoldingLot.order(:id).pluck(:id)
      assert_equal [ 5, 10 ], [ HoldingLot.opening.sole.qty, HoldingLot.derived.sole.qty ], "the 5 held before the trade open a lot"

      provider_row.remap_security!(replacement)
      assert_equal [ replacement.id ], HoldingLot.distinct.pluck(:security_id)
      materialize(:reverse, security_ids: [ replacement.id ])

      provider_row.reload.reset_security_to_provider!

      assert_equal ids, HoldingLot.order(:id).pluck(:id)
      assert_equal [ original.id ], HoldingLot.distinct.pluck(:security_id)
      assert_equal original.id, HoldingLot.opening.sole.origin_security_id
    end
  end

  test "remap onto a position with its own opening lot leaves one opening lot there" do
    setup_account
    old_security = priced_security("LOTQ", 30)
    new_security = priced_security("LOTW", 30)
    holding = @account.holdings.create!(security: old_security, date: d(10), qty: 4, price: 30, amount: 120, currency: "USD")
    moved = opening_lot(old_security, 4)
    kept = opening_lot(new_security, 6)

    holding.remap_security!(new_security)

    assert_equal [ kept.id ], HoldingLot.opening.where(security: new_security).pluck(:id)
    assert_not HoldingLot.exists?(moved.id), "restated into the target's opening lot by the next materialization"
  end

  private
    def d(day)
      Date.new(2024, 6, day)
    end

    def setup_account
      @family = families(:empty)
      @account = @family.accounts.create!(name: "Lots", balance: 20000, cash_balance: 20000, currency: "USD", accountable: Investment.new)
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

    def trade(security, qty, price, day, label: nil)
      entry = create_trade(security, account: @account, qty: qty, price: price, date: d(day))
      entry.entryable.update!(investment_activity_label: label) if label
      entry
    end

    def provider_holding(security, qty, basis)
      @account.holdings.create!(
        security: security, date: d(10), qty: qty, price: 30, amount: qty * 30, currency: "USD",
        cost_basis: basis, cost_basis_source: basis && "provider", account_provider: @account_provider
      )
    end

    def opening_lot(security, qty)
      HoldingLot.create!(account: @account, security: security, origin_security: security, qty: qty, currency: "USD")
    end

    # A linked account: a provider-only position, a position with 2 units held
    # before its first imported trade, and an import whose trades add up to
    # more than the provider reports.
    def build_reverse_fixture
      setup_account
      link_account
      @provider_only = priced_security("LOTF", 30)
      @opening = priced_security("LOTG", 30)
      @gapped = priced_security("LOTH", 30)

      trade(@opening, 10, 100, 3)
      trade(@opening, -4, 30, 5)
      trade(@opening, 2, 110, 7)
      trade(@gapped, 5, 100, 2)
      trade(@gapped, 5, 150, 4)

      provider_holding(@provider_only, 10, 50)
      provider_holding(@opening, 10, nil)
      provider_holding(@gapped, 3, nil)
    end

    def materialize(strategy, security_ids: nil)
      Holding::Materializer.new(@account.reload, strategy: strategy, security_ids: security_ids).materialize_holdings
    end

    def holding_qty(security, date)
      @account.holdings.find_by!(security: security, date: date).qty
    end
end
