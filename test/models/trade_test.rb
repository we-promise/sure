require "test_helper"

class TradeTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include SqlQueryCapture
  # `Trend#value` is `current - previous`, and `Money#-` keeps the left
  # operand's currency while taking the right one's bare amount without
  # converting or raising. So a disposal priced in the security's currency had
  # a basis denominated in the account's subtracted from it as a plain number,
  # and the difference was then labelled with the disposal's currency.
  #
  # A USD account holding a EUR-listed security: basis 100 USD/share, 2 sold at
  # 150 EUR/share, EUR->USD 1.5 on the trade date. 300 EUR of proceeds is 450
  # USD, less 200 USD of basis, so 250 USD. The unconverted subtraction
  # reported 100 -- and then Reports scaled that wrong difference by the rate.
  test "a disposal priced in another currency converts its proceeds at the trade date" do
    sell = cross_currency_disposal(rate: 1.5)

    assert_equal BigDecimal(250), sell.realized_gain_loss.value.amount
    assert_equal "USD", sell.realized_gain_loss.value.currency.iso_code,
                 "the figure is carried in the currency the position is held in"
  end

  # The same defect at a rate below parity OVERSTATES, so a test at one rate
  # cannot pass by accident of direction. 300 EUR at 0.7 is 210 USD, less 200
  # USD of basis: a 10 USD gain, where the bare subtraction claimed 100.
  test "a disposal at a rate below parity is not overstated" do
    sell = cross_currency_disposal(rate: 0.7)

    assert_equal BigDecimal(10), sell.realized_gain_loss.value.amount
  end

  # A disposal's fee is what selling cost, so it comes off the proceeds before
  # they are converted. 2 sold at 150 EUR less a 10 EUR fee is 290 EUR, 435 USD
  # at 1.5, less 200 USD of basis: a 235 USD gain, where ignoring the fee
  # reported 250.
  test "a disposal's fee comes off its proceeds" do
    sell = cross_currency_disposal(rate: 1.5, fee: 10)

    assert_equal BigDecimal(235), sell.realized_gain_loss.value.amount
  end

  # A lot cost what was paid for it, fee included: 10 bought at 100 with a 20
  # fee cost 1,020, so at 120 the lot is up 180, not 200.
  test "a purchase's unrealized gain is measured against its price plus its fee" do
    account, security = cross_currency_account
    buy = create_trade(security, account: account, qty: 10, date: Date.current, price: 100, fee: 20, currency: "USD").entryable
    buy.security.stubs(:current_price).returns(Money.new(120, "USD"))

    assert_equal BigDecimal(180), buy.unrealized_gain_loss.value.amount
  end

  # A quote comes in the listing's currency, which need not be the trade's.
  # `Money#-` takes the right operand's bare amount, so a 200 USD quote against
  # a 180 EUR purchase price read as a 20 "EUR" gain per share. 10 bought at
  # 180 EUR, quoted at 200 USD with USD->EUR 0.9: worth 1,800 EUR, no gain.
  test "a purchase's unrealized gain converts a quote in another currency to the trade's" do
    buy = cross_currency_purchase
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)

    gain = buy.unrealized_gain_loss

    assert_equal BigDecimal(0), gain.value.amount
    assert_equal "EUR", gain.value.currency.iso_code
    assert_equal BigDecimal(1800), gain.current.amount
  end

  # No rate means the gain is unknown, not the figure a rate of 1.0 would give.
  test "a purchase quoted in another currency with no rate has no unrealized gain" do
    buy = cross_currency_purchase
    ExchangeRate.stubs(:provider).returns(nil)

    assert_nil buy.unrealized_gain_loss
  end

  # No rate for that date means the gain is unknown, not zero and not the
  # figure a rate of 1.0 would produce.
  test "a cross-currency disposal with no rate for its date has no figure" do
    sell = cross_currency_disposal(rate: 1.5, rate_date: Date.new(2026, 3, 9))

    assert_nil sell.realized_gain_loss, "a neighbouring day's rate is not this day's"
    assert sell.realized_gain_unconvertible?
  end

  # No rate on any date means the gain is unknown, not zero and not the figure
  # a rate of 1.0 would produce, and the caller can tell why.
  test "a cross-currency disposal with no rate at all has no figure and says why" do
    sell = cross_currency_disposal(rate: 1.5)
    ExchangeRate.where(from_currency: "EUR", to_currency: "USD").delete_all

    assert_nil sell.realized_gain_loss
    assert sell.realized_gain_unconvertible?
  end

  # `exchange_rates` no longer stores a 0 or a negative, but the conversion
  # still guards against being handed one. Multiplying by one is not a
  # conversion: at 0 the 300 EUR of proceeds become nothing and the disposal
  # reports a 200 USD total loss the user never took, and at -1.5 the proceeds
  # go negative and the loss is 650. Neither is distinguishable on the page
  # from a real one, and both are tax-relevant.
  #
  # A rate that cannot convert is the missing-rate case, whatever supplied it,
  # so it takes the same exit as an absent one.
  test "a disposal whose rate cannot convert has no figure" do
    [ 0, -1.5 ].each do |rate|
      # Each case needs the same EUR->USD date, which is unique per pair.
      ExchangeRate.where(from_currency: "EUR", to_currency: "USD").delete_all
      sell = cross_currency_disposal(rate: 1.5)
      sell.preloaded_exchange_rates = { [ "EUR", "USD", sell.entry.date ] => rate }

      assert_nil sell.realized_gain_loss, "a rate of #{rate} converts nothing"
    end
  end

  # One query for the rates a whole page of disposals needs, rather than one
  # per foreign disposal. Each disposal falls on its own date, because
  # identical lookups are served by the query cache and a single-date fixture
  # reads as flat whether the preload runs or not.
  #
  # The preload runs INSIDE the capture, which is the difference between
  # counting what the page costs and counting what is left after the expensive
  # part already happened. With it outside, the assertion was "measuring
  # disposals issues no further rate queries" -- true, and it would stay true
  # if `preload_exchange_rates` itself issued one query per trade. One query
  # for the whole set is the claim, so one query for the whole set is what is
  # counted.
  test "preloading answers every disposal's rate in one query" do
    account, security = cross_currency_account

    trades = (0..3).map do |offset|
      date = Date.new(2026, 3, 10) + offset
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.5)
      account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                               amount: BigDecimal(750), currency: "USD", cost_basis: 100)
      create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR").entryable
    end

    # Outside the capture on purpose: the cost being counted is the rates', not
    # the holdings'.
    holdings = account.holdings.to_a
    trades.each { |trade| trade.preloaded_holdings = holdings }

    queries = capture_sql_queries do
      Trade.preload_exchange_rates(trades)
      trades.each { |trade| trade.realized_gain_loss }
    end.grep(/exchange_rates/)

    assert_equal 1, queries.size,
                 "four disposals on four dates cost one rate query, not one each"
    assert_equal [ BigDecimal(250) ] * 4, trades.map { |t| t.realized_gain_loss.value.amount }
  end

  # The preload keys its basis side on the ACCOUNT's currency; the conversion
  # targets the currency the POSITION is carried in. Those differ in exactly the
  # shape this change exists for -- a EUR disposal of a GBP position in a USD
  # account -- so every such disposal missed the preload and issued the lookup
  # the preload is here to remove. The keys have to come from the holding that
  # `realized_gain_loss` will actually select.
  test "preloading answers a disposal against a position carried in a third currency" do
    account, security = cross_currency_account

    trades = (0..3).map do |offset|
      date = Date.new(2026, 3, 10) + offset
      ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", date: date, rate: 0.8)
      account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                               amount: BigDecimal(750), currency: "GBP", cost_basis: 100)
      create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR").entryable
    end

    holdings = account.holdings.to_a
    trades.each { |trade| trade.preloaded_holdings = holdings }

    queries = capture_sql_queries do
      Trade.preload_exchange_rates(trades)
      trades.each { |trade| trade.realized_gain_loss }
    end.grep(/exchange_rates/)

    assert_equal 1, queries.size,
                 "a position in a third currency costs one rate query for the set, not one each"
    # 2 units at 150 EUR is 300 EUR of proceeds, 240 GBP at 0.8, against a basis
    # of 2 x 100 GBP.
    assert_equal [ BigDecimal(40) ] * 4, trades.map { |t| t.realized_gain_loss.value.amount }
  end

  # A sale that closes the position leaves a snapshot holding nothing, with no
  # stored basis, so the snapshot cannot say what the units cost. Average cost
  # does not move on a sale, so the sale is priced at the average before it:
  # 10 at 100 and 10 at 200 is 3,000 for 20, sold at 180 for 3,600, a 600
  # gain. Replaying through the sale itself closes the position and leaves no
  # figure at all.
  test "a sale that closes the position realises its gain against the cost before the sale" do
    account, security = cross_currency_account
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 2), price: 100)
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 3), price: 200)
    sell = create_trade(security, account: account, qty: -20, date: Date.new(2026, 3, 4), price: 180).entryable
    closed_snapshot(account, security, Date.new(2026, 3, 4))

    gain = sell.realized_gain_loss

    assert_not_nil gain, "a closing sale still realises a gain"
    assert_equal BigDecimal(3000), gain.previous.amount
    assert_equal BigDecimal(600), gain.value.amount
  end

  # Bought and sold on one day, the only snapshot is the closed one and there
  # is no earlier day to read a cost from. The buy sorts before the sale in
  # Entry.chronological order, so it is the cost: 10 at 100 sold at 130 is a
  # 300 gain.
  test "a position bought and sold on the same day realises its gain" do
    account, security = cross_currency_account
    date = Date.new(2026, 3, 4)
    create_trade(security, account: account, qty: 10, date: date, price: 100)
    sell = create_trade(security, account: account, qty: -10, date: date, price: 130).entryable
    closed_snapshot(account, security, date)

    gain = sell.realized_gain_loss

    assert_not_nil gain, "the same day's buy is the cost"
    assert_equal BigDecimal(300), gain.value.amount
  end

  # An import stamps a day's trades with one created_at, and the calculators
  # then replay a buy before a sale whatever their ids
  # (Holding::PortfolioCache#trades). The sale's cost must too, even when the
  # sale's id sorts first.
  test "a same-day sale imported with its buy realises its gain whatever the ids" do
    account, security = cross_currency_account
    date = Date.new(2026, 3, 4)
    buy = create_trade(security, account: account, qty: 10, date: date, price: 100)
    sell_entry = create_trade(security, account: account, qty: -10, date: date, price: 130)
    stamp = Time.zone.local(2026, 3, 4, 9)
    Entry.where(id: [ buy.id, sell_entry.id ]).update_all(created_at: stamp)
    sell_entry.update_columns(id: "00000000-0000-0000-0000-000000000001")
    closed_snapshot(account, security, date)

    gain = Trade.find(sell_entry.entryable_id).realized_gain_loss

    assert_not_nil gain, "the same day's buy is the cost"
    assert_equal BigDecimal(300), gain.value.amount
  end

  # A provider can hold a position in the security's currency rather than the
  # account's, and the replayed cost is then in that currency too. 10 bought
  # at 100 EUR and sold at 130 EUR is a 300 EUR gain; costing the units in
  # USD (150 each at 1.5) but labelling them EUR reported a 200 EUR loss.
  test "a closing sale of a position held in another currency realises its gain in that currency" do
    account, security = cross_currency_account
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 3, 2), rate: 1.5)
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 2), price: 100, currency: "EUR")
    sell = create_trade(security, account: account, qty: -10, date: Date.new(2026, 3, 4), price: 130, currency: "EUR").entryable
    account.holdings.create!(security: security, date: Date.new(2026, 3, 4), qty: 0, price: 0,
                             amount: 0, currency: "EUR", cost_basis: nil)

    gain = sell.realized_gain_loss

    assert_equal Money.new(BigDecimal(1000), "EUR"), gain.previous
    assert_equal Money.new(BigDecimal(300), "EUR"), gain.value
  end

  # A split applies at the open of its ex-date, before that day's trades. 10
  # bought at 100 become 20 at 50 on a 2-for-1 split; all 20 sold that day at
  # 70 is 1,400 against 1,000, a 400 gain. Pricing the 20 units at the
  # pre-split 100 would report a 600 loss.
  test "a closing sale after a split uses the split-adjusted cost" do
    account, security = cross_currency_account
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 2), price: 100)
    security.splits.create!(ex_date: Date.new(2026, 3, 4), numerator: 2, denominator: 1, source: "manual")
    sell = create_trade(security, account: account, qty: -20, date: Date.new(2026, 3, 4), price: 70).entryable
    closed_snapshot(account, security, Date.new(2026, 3, 4))

    gain = sell.realized_gain_loss

    assert_not_nil gain
    assert_equal BigDecimal(1000), gain.previous.amount
    assert_equal BigDecimal(400), gain.value.amount
  end

  # A sale that leaves units held keeps reading the snapshot's own figure. The
  # stored 160 is deliberately not what the trades replay to (150), so this
  # fails if the replay ever displaces a basis the snapshot has: 5 sold at 180
  # is 900 against 800, a 100 gain.
  test "a partial sale's realized gain is unchanged" do
    account, security = cross_currency_account
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 2), price: 100)
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 3), price: 200)
    sell = create_trade(security, account: account, qty: -5, date: Date.new(2026, 3, 4), price: 180).entryable
    account.holdings.create!(security: security, date: Date.new(2026, 3, 4), qty: 15, price: 180,
                             amount: BigDecimal(2700), currency: "USD", cost_basis: 160)

    gain = sell.realized_gain_loss

    assert_equal BigDecimal(800), gain.previous.amount
    assert_equal BigDecimal(100), gain.value.amount
  end

  # With no stored basis, the snapshot's own figure is unknown, and the cost
  # before the sale is all the gain needs. Replaying the history for the
  # snapshot first, only to find a closed position, then replaying it again up
  # to the sale, reads every trade and split twice on each sale Reports prices.
  test "realized gain on a closing sale with no stored basis replays the history once" do
    account, security = cross_currency_account
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 2), price: 100)
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 3), price: 200)
    sell = create_trade(security, account: account, qty: -20, date: Date.new(2026, 3, 4), price: 180).entryable
    closed_snapshot(account, security, Date.new(2026, 3, 4))
    sell.entry.account

    gain = nil
    # Uncached, so a second replay counts rather than hitting the query cache.
    queries = ActiveRecord::Base.uncached { capture_sql_queries { gain = sell.realized_gain_loss } }

    assert_equal 1, queries.count { |sql| sql.include?('FROM "trades"') }
    assert_equal 1, queries.count { |sql| sql.include?('FROM "security_splits"') }
    assert_equal BigDecimal(600), gain.value.amount
  end

  # Units sold beyond the position are priced at the acquisitions that cover
  # them, as a fifo sale's shortfall is (Holding::LotBook#cover): 5 held at
  # 100 and 5 covered by the same day's later buy at 200 is 1,500 against
  # 1,800 of proceeds.
  test "a sale beyond the position prices the units held at the average and the rest at their cover" do
    account, security = cross_currency_account
    closed_snapshot(account, security, Date.new(2026, 3, 1))
    create_trade(security, account: account, qty: 5, date: Date.new(2026, 3, 2), price: 100)
    sale = create_trade(security, account: account, qty: -10, date: Date.new(2026, 3, 3), price: 180)
    cover = create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 3), price: 200)
    cover.update_columns(created_at: sale.created_at + 1.second)

    assert_equal BigDecimal(300), sale.entryable.realized_gain_loss.value.amount
  end

  # An earlier sale's shortfall is covered first, so this one takes the 200.
  test "a sale beyond the position is covered after an earlier sale's shortfall" do
    account, security = cross_currency_account
    closed_snapshot(account, security, Date.new(2026, 3, 1))
    create_trade(security, account: account, qty: -5, date: Date.new(2026, 3, 2), price: 180)
    sale = create_trade(security, account: account, qty: -5, date: Date.new(2026, 3, 3), price: 180)
    create_trade(security, account: account, qty: 5, date: Date.new(2026, 3, 4), price: 100)
    create_trade(security, account: account, qty: 5, date: Date.new(2026, 3, 5), price: 200)

    assert_equal BigDecimal(-100), sale.entryable.realized_gain_loss.value.amount
  end

  # Nothing covers the shortfall, a transfer in or a foreign buy with no rate
  # covers it at a cost nothing here knows, a split comes before the cover, or
  # the units held have no known cost: each leaves the sale's cost unknown.
  test "a sale beyond the position with no known cover realises no gain" do
    cases = {
      uncovered: [ [ 5, 100, 2 ], [ :sale, 3 ] ],
      transfer_cover: [ [ :sale, 2 ], [ :transfer, 3 ], [ 5, 100, 4 ] ],
      unpriced_cover: [ [ :sale, 2 ], [ :unpriced, 3 ] ],
      split_first: [ [ :sale, 2 ], [ :split, 3 ], [ 10, 100, 4 ] ],
      unknown_held: [ [ :transfer, 2 ], [ :sale, 3 ], [ 10, 200, 4 ] ]
    }

    gains = cases.transform_values do |steps|
      account, security = cross_currency_account
      closed_snapshot(account, security, Date.new(2026, 3, 1))
      sale = nil
      steps.each do |kind, *rest|
        day = Date.new(2026, 3, rest.last)
        case kind
        when :sale then sale = create_trade(security, account: account, qty: -10, date: day, price: 180)
        when :transfer
          moved_in = create_trade(security, account: account, qty: 5, date: day, price: 100)
          moved_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
        when :split then security.splits.create!(ex_date: day, numerator: 2, denominator: 1, source: "manual")
        when :unpriced then create_trade(security, account: account, qty: 10, date: day, price: 100, currency: "CAD")
        else create_trade(security, account: account, qty: kind, date: day, price: rest.first)
        end
      end
      sale.entryable.realized_gain_loss
    end

    assert_equal cases.keys.index_with(nil), gains
  end

  # A reverse-synced account with two shares from before its first imported
  # trade: 10 bought, 5 moved in, 15 sold, 8 bought at 150, then 3 sold. The
  # -15 sale left two shares, so the transferred units were never cleared out
  # and the cost of what the later sale disposes of is unknown -- pricing it
  # at the rebuy's 150 would book a gain the history cannot support.
  test "a sale after opening shares kept transferred units held realises no gain" do
    account, security = cross_currency_account
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 2), price: 100)
    transfer_in = create_trade(security, account: account, qty: 5, date: Date.new(2026, 3, 3), price: 120)
    transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
    create_trade(security, account: account, qty: -15, date: Date.new(2026, 3, 4), price: 130)
    create_trade(security, account: account, qty: 8, date: Date.new(2026, 3, 5), price: 150)
    sell = create_trade(security, account: account, qty: -3, date: Date.new(2026, 3, 6), price: 170).entryable
    account.holdings.create!(security: security, date: Date.new(2026, 3, 6), qty: 7, price: 170,
                             amount: BigDecimal(1190), currency: "USD", cost_basis: nil)

    assert_nil sell.realized_gain_loss
  end

  # The latest snapshot on or before the sale can predate trades the replay
  # still needs. Its quantity explains the trades up to its own date only:
  # the 8 held on 3/5 is the whole history (10 in, 5 moved in, 15 sold, 8
  # bought), so the position did close and the transfer is released. The 3
  # sold on 3/6 came after the snapshot, and undoing it too would invent 3
  # opening shares that keep the transfer held. 2 sold at 170 against 150 is
  # a 40 gain.
  test "a sale after the snapshot's date walks back only the snapshot's trades" do
    account, security = cross_currency_account
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 2), price: 100)
    transfer_in = create_trade(security, account: account, qty: 5, date: Date.new(2026, 3, 3), price: 120)
    transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
    create_trade(security, account: account, qty: -15, date: Date.new(2026, 3, 4), price: 130)
    create_trade(security, account: account, qty: 8, date: Date.new(2026, 3, 5), price: 150)
    create_trade(security, account: account, qty: -3, date: Date.new(2026, 3, 6), price: 160)
    sell = create_trade(security, account: account, qty: -2, date: Date.new(2026, 3, 7), price: 170).entryable
    account.holdings.create!(security: security, date: Date.new(2026, 3, 5), qty: 8, price: 150,
                             amount: BigDecimal(1200), currency: "USD", cost_basis: nil)

    gain = sell.realized_gain_loss

    assert_not_nil gain, "the history explains the whole position, so the rebuy is the cost"
    assert_equal BigDecimal(300), gain.previous.amount
    assert_equal BigDecimal(40), gain.value.amount
  end

  # A sale is measured against its security's latest position on or before the
  # sale: one row. Preloading used to read every holding of the sale's account
  # instead, a row per security per day of its history.
  test "preloading reads each disposal's basis position in one query" do
    account, security = cross_currency_account
    other = Security.create!(ticker: "OTH#{SecureRandom.hex(3)}", name: "Other")

    (0..9).each do |offset|
      date = Date.new(2026, 3, 1) + offset
      account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                               amount: BigDecimal(750), currency: "USD", cost_basis: 100 + offset)
      account.holdings.create!(security: other, date: date, qty: 5, price: 10,
                               amount: BigDecimal(50), currency: "USD", cost_basis: 8)
    end
    early = create_trade(security, account: account, qty: -2, date: Date.new(2026, 3, 3), price: 150, currency: "USD").entryable
    late = create_trade(security, account: account, qty: -2, date: Date.new(2026, 3, 20), price: 150, currency: "USD").entryable
    unheld = create_trade(Security.create!(ticker: "NEW#{SecureRandom.hex(3)}", name: "Never held"),
                          account: account, qty: -1, date: Date.new(2026, 3, 5), price: 10, currency: "USD").entryable
    trades = Trade.where(id: [ early, late, unheld ].map(&:id)).includes(:entry).to_a

    queries = capture_sql_queries { Trade.preload_basis_holdings(trades) }.grep(/holdings/)

    assert_equal 1, queries.size, "three disposals cost one holdings query, not one each"
    by_id = trades.index_by(&:id)
    # The position on the sale's own date, and for a sale after the last
    # snapshot the last one: never a later day's, nor another security's.
    assert_equal BigDecimal(2 * 150 - 2 * 102), by_id[early.id].realized_gain_loss.value.amount
    assert_equal BigDecimal(2 * 150 - 2 * 109), by_id[late.id].realized_gain_loss.value.amount
    assert_no_queries_matching(/holdings/) { by_id[unheld.id].realized_gain_loss }
  end

  # A basis holding without a stored cost basis falls back to averaging its
  # buys, which on its own is several queries per sale.
  test "preloading reads the basis positions' average costs in the same pass" do
    account, security = cross_currency_account
    create_trade(security, account: account, qty: 10, date: Date.new(2026, 3, 1), price: 100, currency: "USD")
    (1..5).each do |day|
      account.holdings.create!(security: security, date: Date.new(2026, 3, day), qty: 10, price: 150,
                               amount: BigDecimal(1500), currency: "USD")
    end
    sales = [ 3, 5 ].map do |day|
      create_trade(security, account: account, qty: -2, date: Date.new(2026, 3, day), price: 150, currency: "USD").entryable
    end
    trades = Trade.where(id: sales.map(&:id)).includes(:entry).to_a
    Trade.preload_basis_holdings(trades)
    trades.each { |trade| trade.preloaded_lot_disposals = nil }

    queries = capture_sql_queries { trades.each(&:realized_gain_loss) }

    assert_empty queries.grep(/SUM\(/), "no sale averages its buys on its own"
    assert_equal [ BigDecimal(100) ] * 2, trades.map { |t| t.realized_gain_loss.value.amount }
  end

  test "a preloaded disposal measures the same as one that looks its position up" do
    account, security = cross_currency_account
    account.holdings.create!(security: security, date: Date.new(2026, 3, 10), qty: 5, price: 150,
                             amount: BigDecimal(750), currency: "USD", cost_basis: 100)
    sale = create_trade(security, account: account, qty: -2, date: Date.new(2026, 3, 12), price: 150, currency: "USD").entryable

    looked_up = Trade.find(sale.id).realized_gain_loss.value
    preloaded = Trade.find(sale.id).tap { |trade| Trade.preload_basis_holdings([ trade ]) }.realized_gain_loss.value

    assert_equal looked_up, preloaded
  end

  # Two snapshots on the same day differ only by currency (a security remap can
  # leave that). Every path settles on the same one, whatever the row order.
  test "a same-day tie resolves to the account's currency on every path" do
    account, security = cross_currency_account
    date = Date.new(2026, 3, 10)
    usd = account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                                   amount: BigDecimal(750), currency: "USD", cost_basis: 100)
    eur = account.holdings.create!(security: security, date: date, qty: 5, price: 140,
                                   amount: BigDecimal(700), currency: "EUR", cost_basis: 90)
    sale = create_trade(security, account: account, qty: -2, date: Date.new(2026, 3, 12), price: 150, currency: "USD").entryable

    looked_up = Trade.find(sale.id).send(:basis_holding)
    preloaded = Trade.find(sale.id).tap { |trade| Trade.preload_basis_holdings([ trade ]) }.send(:basis_holding)
    given = [ [ eur, usd ], [ usd, eur ] ].map do |order|
      Trade.find(sale.id).tap { |trade| trade.preloaded_holdings = order }.send(:basis_holding)
    end

    assert_equal [ usd.id ] * 4, [ looked_up, preloaded, *given ].map(&:id)
  end

  test "build_name generates buy trade name" do
    name = Trade.build_name("buy", 10, "AAPL")
    assert_equal "Buy 10.0 shares of AAPL", name
  end

  test "build_name generates sell trade name" do
    name = Trade.build_name("sell", 5, "MSFT")
    assert_equal "Sell 5.0 shares of MSFT", name
  end

  test "build_name handles absolute value for negative quantities" do
    name = Trade.build_name("sell", -5, "GOOGL")
    assert_equal "Sell 5.0 shares of GOOGL", name
  end

  test "build_name handles decimal quantities" do
    name = Trade.build_name("buy", 0.25, "BTC")
    assert_equal "Buy 0.25 shares of BTC", name
  end

  test "price scale is preserved at 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # up to 10 decimal places — should persist exactly
    precise_price = BigDecimal("12.3456789012")
    trade = Trade.create!(
      security: security,
      price: precise_price,
      qty: 10000,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal precise_price, trade.price
  end

  test "fee defaults to 0" do
    security = Security.create!(ticker: "FEETEST", exchange_operating_mic: "XNAS")
    trade = Trade.create!(
      security: security,
      price: 100,
      qty: 10,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    assert_equal 0, trade.fee
  end

  test "exchange_rate setter stores normalized numeric value in extra" do
    trade = Trade.new
    trade.exchange_rate = "0.91"

    assert_equal 0.91, trade.exchange_rate
    assert_equal 0.91, trade.extra["exchange_rate"]
  end

  test "exchange_rate validation rejects invalid values" do
    trade = Trade.new
    trade.exchange_rate = "invalid"

    assert_not trade.valid?
    assert_includes trade.errors[:exchange_rate], "must be a number"
  end

  test "exchange_rate validation rejects non-finite values" do
    trade = Trade.new
    trade.exchange_rate = "NaN"

    assert_not trade.valid?
    assert_includes trade.errors[:exchange_rate], "must be a number"
  end

  test "price is rounded to 10 decimal places" do
    security = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")

    # over 10 decimal places — will be rounded
    price_with_too_many_decimals = BigDecimal("1.123456789012345")
    trade = Trade.create!(
      security: security,
      price: price_with_too_many_decimals,
      qty: 1,
      currency: "USD",
      investment_activity_label: "Buy"
    )

    trade.reload

    assert_equal BigDecimal("1.1234567890"), trade.price
  end

  test "a transfer out realises nothing, however it is priced" do
    account, security = position_with_known_cost_basis

    moved = build_negative_trade(account, security, label: "Transfer")
    sold  = build_negative_trade(account, security, label: "Sell")

    # Same sign, same shape, same price — only the label separates a sale from
    # coins walking to another wallet you own.
    assert_nil moved.realized_gain_loss
    assert_not_nil sold.realized_gain_loss
  end

  test "every internal movement label realises nothing" do
    account, security = position_with_known_cost_basis

    Trade::INTERNAL_MOVEMENT_LABELS.each do |label|
      trade = build_negative_trade(account, security, label: label)
      assert_nil trade.realized_gain_loss, "#{label} should not realise a gain"
    end
  end

  private
    def assert_no_queries_matching(pattern, &block)
      assert_empty capture_sql_queries(&block).grep(pattern)
    end

    # A position whose cost basis is known, which is what makes a fabricated
    # gain possible: without one, realized_gain_loss returns nil for any reason.
    def position_with_known_cost_basis
      family = families(:empty)
      account = family.accounts.create!(name: "Wallet", balance: 100, currency: "USD",
                                        accountable: Investment.new)
      security = Security.find_or_create_by!(ticker: "MOVE") { |s| s.name = "Movable" }
      Holding.create!(account: account, security: security, date: 10.days.ago.to_date,
                      qty: 100, price: 2, amount: 200, currency: "USD", cost_basis: 1)

      [ account, security ]
    end

    def build_negative_trade(account, security, label:)
      account.entries.create!(
        date: 3.days.ago.to_date, name: "out #{label}", amount: 0, currency: "USD",
        entryable: Trade.new(security: security, qty: -40, price: 3, currency: "USD",
                             investment_activity_label: label)
      ).entryable
    end

    # "Exchange" means a currency exchange on cash and is internal there. On a
    # security the label covers currency *or security* exchanges, and a
    # security-for-security exchange can dispose of an appreciated asset — so
    # borrowing Transaction's list erased a realized gain with nothing to show
    # for it.
    test "an exchange is not treated as an internal movement on a trade" do
      assert_not Trade.new(investment_activity_label: "Exchange").internal_movement?
    end

    test "the labels that unambiguously preserve ownership still are" do
      %w[Transfer Sweep\ In Sweep\ Out].each do |label|
        assert Trade.new(investment_activity_label: label).internal_movement?, label
      end
    end

    # The two lists are deliberately different; this fails if one is ever
    # aliased back onto the other.
    test "a trade does not borrow the cash list" do
      assert_includes Transaction::INTERNAL_MOVEMENT_LABELS, "Exchange"
      assert_not_includes Trade::INTERNAL_MOVEMENT_LABELS, "Exchange"
    end

  private
    # A USD account holding a EUR-listed security, with one disposal in it.
    def cross_currency_disposal(rate:, rate_date: Date.new(2026, 3, 10), fee: 0)
      account, security = cross_currency_account
      date = Date.new(2026, 3, 10)

      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: rate_date, rate: rate)
      account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                               amount: BigDecimal(750), currency: "USD", cost_basis: 100)

      create_trade(security, account: account, qty: -2, date: date, price: 150, fee: fee, currency: "EUR").entryable
    end

    # The snapshot the calculators write on the day a position closes: nothing
    # held and no basis.
    def closed_snapshot(account, security, date)
      account.holdings.create!(security: security, date: date, qty: 0, price: 0,
                               amount: 0, currency: "USD", cost_basis: nil)
    end

    def cross_currency_account
      account = families(:empty).accounts.create!(
        name: "Brokerage", balance: 10_000, currency: "USD", accountable: Investment.new
      )
      security = Security.create!(ticker: "EUX#{SecureRandom.hex(3)}", name: "Euro Listed")

      [ account, security ]
    end

    def cross_currency_purchase
      account = families(:empty).accounts.create!(
        name: "Depot", balance: 10_000, currency: "EUR", accountable: Investment.new
      )
      security = Security.create!(ticker: "USX#{SecureRandom.hex(3)}", name: "Dollar Listed")
      buy = create_trade(security, account: account, qty: 10, date: Date.current, price: 180, currency: "EUR").entryable
      buy.security.stubs(:current_price).returns(Money.new(200, "USD"))
      buy
    end

    test "label_for_side follows the side for Buy, Sell and a missing label, and keeps any other activity" do
      trade = Trade.new(investment_activity_label: "Buy")
      assert_equal "Sell", trade.label_for_side(sell: true)

      trade.investment_activity_label = "Sell"
      assert_equal "Buy", trade.label_for_side(sell: false)

      trade.investment_activity_label = nil
      assert_equal "Sell", trade.label_for_side(sell: true)

      trade.investment_activity_label = "Sweep In"
      assert_equal "Sweep In", trade.label_for_side(sell: true)
    end
end
