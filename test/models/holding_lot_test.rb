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

  # Rails' upsert with update_only moves updated_at only when a listed column
  # changes, for both kinds of lot.
  test "re-materializing moves a lot's updated_at only when the lot changes" do
    travel_to TODAY do
      build_reverse_fixture
      materialize(:reverse)
      derived = HoldingLot.derived.find_by!(security: @opening, acquired_on: d(3))
      opening = HoldingLot.opening.find_by!(security: @opening)
      stale = 1.day.ago.change(usec: 0)
      HoldingLot.where(id: [ derived.id, opening.id ]).update_all(updated_at: stale)

      materialize(:reverse)
      assert_equal [ stale, stale ], [ derived.reload.updated_at, opening.reload.updated_at ], "nothing changed"

      trade(@opening, -2, 30, 8)
      @account.holdings.find_by!(security: @opening, date: d(10)).update!(qty: 12, amount: 360)
      materialize(:reverse)
      assert_operator derived.reload.updated_at, :>, stale, "the sale relieved the lot"
      assert_operator opening.reload.updated_at, :>, stale, "the opening lot was restated"
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

  # 10 / 1.5 rounds to 18 places and back to 10.000000000000000001; the
  # opening lot takes that rounding, so the lots add up to the holding.
  test "a split that does not divide evenly leaves the lots adding up to the provider's quantity" do
    travel_to TODAY do
      setup_account
      link_account
      security = priced_security("SPL3", 30)
      trade(security, 2, 10, 2)
      Security::Split.create!(security: security, ex_date: d(4), numerator: 3, denominator: 2, source: "manual")
      @account.holdings.create!(security: security, date: d(10), qty: 10, price: 30, amount: 300, currency: "USD", account_provider: @account_provider)

      materialize(:reverse)

      lots = HoldingLot.where(account: @account, security: security)
      assert_equal BigDecimal("10"), lots.sum(:qty)
      assert_equal [ BigDecimal("7"), BigDecimal("3") ], [ lots.opening.sole.qty, lots.derived.sole.qty ], "only the opening lot moved"
    end
  end

  # Fixtures only ever leave 10^-18; a real gap is far wider and is not
  # rounding, so it stays a difference the lots show.
  test "the opening lot does not absorb a residual above the bound" do
    book = Holding::LotBook.new
    book.add_unknown(BigDecimal("10"))
    book.apply(BigDecimal("10"), 2, source_id: "buy")

    book.settle_opening(BigDecimal("12.000001"), bound: Holding::LotBook::OPENING_RESIDUAL_BOUND)
    assert_equal [ BigDecimal("10"), BigDecimal("2") ], book.lots.map(&:qty), "above the bound"

    book.settle_opening(BigDecimal("12.000000000001"), bound: Holding::LotBook::OPENING_RESIDUAL_BOUND)
    assert_equal [ BigDecimal("10.000000000001"), BigDecimal("2") ], book.lots.map(&:qty), "at the bound"
  end

  # buy, sell and add_unknown all read their quantity through to_d.
  test "the residual target is read as a decimal, as the other book entries are" do
    book = Holding::LotBook.new
    book.add_unknown(BigDecimal("12"))

    book.settle_opening("12.000000000001", bound: Holding::LotBook::OPENING_RESIDUAL_BOUND)

    assert_equal [ BigDecimal("12.000000000001") ], book.lots.map(&:qty)
  end

  test "the residual never takes a lot to nothing" do
    book = Holding::LotBook.new
    book.add_unknown(BigDecimal("1e-13"))

    book.settle_opening(BigDecimal("0"), bound: Holding::LotBook::OPENING_RESIDUAL_BOUND)

    assert_equal [ BigDecimal("1e-13") ], book.lots.map(&:qty)
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
      assert_equal BigDecimal("102.5"), @account.holdings.find_by!(security: @opening, date: d(9)).cost_basis

      @account.holdings.find_by!(security: @opening, date: d(10)).update!(qty: 5, amount: 150)
      materialize(:reverse)

      lot.reload
      assert_equal [ 0, true ], [ lot.qty, lot.clamped ], "5 reported against 8 traded"
      assert_nil @account.holdings.find_by!(security: @opening, date: d(9)).cost_basis, "the stored figure is cleared"
    end
  end

  test "an opening lot goes once the trades explain the whole position" do
    travel_to TODAY do
      build_reverse_fixture
      materialize(:reverse)
      assert HoldingLot.opening.exists?(security: @opening)

      @account.holdings.find_by!(security: @opening, date: d(10)).update!(qty: 8, amount: 240)
      materialize(:reverse)

      assert_not HoldingLot.opening.exists?(security: @opening), "8 reported against 8 traded"
      assert_equal 8, HoldingLot.where(security: @opening).sum(:qty)
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

  test "remap onto a position with its own opening lot merges the two" do
    setup_account
    old_security = priced_security("LOTQ", 30)
    new_security = priced_security("LOTW", 30)
    holding = @account.holdings.create!(security: old_security, date: d(10), qty: 4, price: 30, amount: 120, currency: "USD")
    moved = opening_lot(old_security, 4)
    kept = opening_lot(new_security, 6)

    holding.remap_security!(new_security)

    assert_equal [ kept.id ], HoldingLot.opening.where(security: new_security).pluck(:id), "the target keeps its row"
    assert_equal 10, kept.reload.qty, "4 moved onto the target's 6"
    assert_not HoldingLot.exists?(moved.id)
  end

  test "merged opening lot keeps its cost only when both sides agree" do
    [ [ 25, 25, 25 ], [ 25, 30, nil ], [ nil, 30, nil ], [ 25, nil, nil ] ].each do |moved_cost, kept_cost, merged_cost|
      setup_account
      old_security = priced_security("LOTM#{moved_cost}#{kept_cost}", 30)
      new_security = priced_security("LOTK#{moved_cost}#{kept_cost}", 30)
      holding = @account.holdings.create!(security: old_security, date: d(10), qty: 4, price: 30, amount: 120, currency: "USD")
      opening_lot(old_security, 4).update!(unit_cost: moved_cost)
      kept = opening_lot(new_security, 6)
      kept.update!(unit_cost: kept_cost)

      holding.remap_security!(new_security)

      assert_equal merged_cost, kept.reload.unit_cost, "moved #{moved_cost.inspect} onto #{kept_cost.inspect}"
    end
  end

  # --- User-set lot cost --------------------------------------------------------

  test "a user-set cost on a transfer-in lot resolves the position, forward" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTU", 30)
      transfer = trade(security, 60, 30, 2, label: Trade::TRANSFER_LABEL)
      trade(security, 40, 20, 3)
      materialize(:forward)
      assert_nil @account.holdings.find_by!(security: security, date: d(10)).cost_basis, "unknown before"

      HoldingLot.find_by!(source_entry: transfer).set_manual_total_cost!(720)
      materialize(:forward)

      assert_equal BigDecimal("15.2"), @account.holdings.find_by!(security: security, date: d(10)).cost_basis
      assert_equal 12, HoldingLot.find_by!(source_entry: transfer).unit_cost
    end
  end

  test "a user-set cost on a transfer-in lot resolves the position, reverse" do
    travel_to TODAY do
      setup_account
      link_account
      security = priced_security("LOTV", 30)
      transfer = trade(security, 60, 30, 2, label: Trade::TRANSFER_LABEL)
      trade(security, 40, 20, 3)
      provider_holding(security, 100, nil)
      materialize(:reverse)
      # d(10) is the provider's own row, which the materializer leaves alone.
      assert_nil @account.holdings.find_by!(security: security, date: d(9)).cost_basis, "unknown before"

      HoldingLot.find_by!(source_entry: transfer).set_manual_total_cost!(720)
      materialize(:reverse)

      assert_equal BigDecimal("15.2"), @account.holdings.find_by!(security: security, date: d(9)).cost_basis
    end
  end

  test "a user-set cost replaces a buy's price, and unlocking returns it to the trade" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTP", 30)
      trade(security, 60, 12, 2)
      buy = trade(security, 40, 20, 3)
      materialize(:forward)
      assert_equal BigDecimal("15.2"), @account.holdings.find_by!(security: security, date: d(10)).cost_basis

      lot = HoldingLot.find_by!(source_entry: buy)
      lot.set_manual_total_cost!(600)
      materialize(:forward)
      assert_equal BigDecimal("13.2"), @account.holdings.find_by!(security: security, date: d(10)).cost_basis, "(720 + 600) / 100"

      lot.reload.unlock_cost!
      materialize(:forward)
      assert_equal BigDecimal("15.2"), @account.holdings.find_by!(security: security, date: d(10)).cost_basis
      assert_nil lot.reload.manual_total_cost
    end
  end

  test "a user-set lot cost survives a split and a partial sale" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTS", 30)
      buy = trade(security, 10, 100, 2)
      Security::Split.create!(security: security, ex_date: d(4), numerator: 2, denominator: 1, source: "manual")
      trade(security, -5, 90, 6)
      materialize(:forward)
      lot = HoldingLot.find_by!(source_entry: buy)
      assert_equal [ 15, 50 ], [ lot.qty, lot.unit_cost ], "20 after the split, 5 sold"

      lot.set_manual_total_cost!(1500)
      materialize(:forward)

      assert_equal 75, lot.reload.unit_cost, "1500 over the 10 bought, halved by the split"
      assert_equal 75, @account.holdings.find_by!(security: security, date: d(10)).cost_basis
    end
  end

  test "a whole-position lock outranks a user-set lot cost" do
    travel_to TODAY do
      setup_account
      security = priced_security("LOTL", 30)
      buy = trade(security, 10, 20, 2)
      materialize(:forward)
      @account.holdings.find_by!(security: security, date: d(10)).set_manual_cost_basis!(99)

      HoldingLot.find_by!(source_entry: buy).set_manual_total_cost!(150)
      materialize(:forward)

      assert_equal 99, @account.holdings.find_by!(security: security, date: d(10)).cost_basis
    end
  end

  # --- Clamped positions ---------------------------------------------------------

  test "provider quantity below trade-derived quantity makes the position unknown" do
    travel_to TODAY do
      build_reverse_fixture
      materialize(:reverse)

      assert_nil @account.holdings.find_by!(security: @gapped, date: d(9)).cost_basis, "trades alone give 125"
      assert_equal BigDecimal("102.5"), @account.holdings.find_by!(security: @opening, date: d(9)).cost_basis, "the control keeps its figure"
    end
  end

  test "the avg-cost fallback answers nil for a clamped position" do
    travel_to TODAY do
      build_reverse_fixture
      materialize(:reverse)
      gapped = @account.holdings.find_by!(security: @gapped, date: d(10))
      control = @account.holdings.find_by!(security: @opening, date: d(10))

      assert_nil Holding.find(gapped.id).avg_cost, "trades alone give 125"
      assert_not_nil Holding.find(control.id).avg_cost
    end
  end

  # --- The fallback reads user-set lot costs ------------------------------------

  test "the avg-cost fallback counts a user-set lot cost, so a linked position resolves" do
    travel_to TODAY do
      setup_account
      link_account
      security = priced_security("LOTR", 30)
      transfer = trade(security, 60, 30, 2, label: Trade::TRANSFER_LABEL)
      buy = trade(security, 40, 20, 3)
      provider_row = provider_holding(security, 100, nil)
      materialize(:reverse)
      assert_nil Holding.find(provider_row.id).avg_cost, "unknown before"

      HoldingLot.find_by!(source_entry: transfer).set_manual_total_cost!(720)
      assert_equal BigDecimal("15.2"), Holding.find(provider_row.id).avg_cost.amount

      HoldingLot.find_by!(source_entry: buy).set_manual_total_cost!(600)
      assert_equal BigDecimal("13.2"), Holding.find(provider_row.id).avg_cost.amount, "(720 + 600) / 100"
    end
  end

  # A run scoped to one security (a remap, a price sync) books lots for that
  # security only: neither the provider snapshot, which covers the whole
  # account, nor the account's other trades open a book.
  test "a reverse run scoped to one security books lots for that security only" do
    travel_to TODAY do
      build_reverse_fixture
      calculator = Holding::ReverseCalculator.new(@account.reload, portfolio_snapshot: Holding::PortfolioSnapshot.new(@account), security_ids: [ @opening.id ])
      calculator.calculate

      assert_equal [ @opening.id ], calculator.lots_by_security.keys
    end
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
