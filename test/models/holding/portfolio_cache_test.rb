require "test_helper"

class Holding::PortfolioCacheTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @provider = mock
    Security.stubs(:provider).returns(@provider)

    @account = families(:empty).accounts.create!(
      name: "Test Brokerage",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )

    @security = Security.create!(name: "Test Security", ticker: "TEST", exchange_operating_mic: "TEST")

    @trade = create_trade(@security, account: @account, qty: 1, date: 2.days.ago.to_date, price: 210.23).trade
  end

  test "a day's trades stamped together come back purchases first, whatever their ids" do
    sale = create_trade(@security, account: @account, qty: -1, date: 1.day.ago.to_date, price: 220)
    purchase = create_trade(@security, account: @account, qty: 1, date: 1.day.ago.to_date, price: 215)
    Entry.where(id: [ sale.id, purchase.id ]).update_all(created_at: Time.zone.parse("2026-01-01 10:00:00"))
    Entry.where(id: sale.id).update_all(id: "00000000-0000-0000-0000-000000000001")
    Entry.where(id: purchase.id).update_all(id: "ffffffff-ffff-ffff-ffff-ffffffffffff")

    cache = Holding::PortfolioCache.new(@account)

    assert_equal [ "ffffffff-ffff-ffff-ffff-ffffffffffff", "00000000-0000-0000-0000-000000000001" ],
                 cache.get_trades(date: 1.day.ago.to_date).map(&:id)
  end

  test "a day's trades with different created_at keep the order they were entered in" do
    sale = create_trade(@security, account: @account, qty: -1, date: 1.day.ago.to_date, price: 220)
    purchase = create_trade(@security, account: @account, qty: 1, date: 1.day.ago.to_date, price: 215)
    Entry.where(id: sale.id).update_all(created_at: 2.hours.ago)
    Entry.where(id: purchase.id).update_all(created_at: 1.hour.ago)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal [ sale.id, purchase.id ], cache.get_trades(date: 1.day.ago.to_date).map(&:id)
  end

  test "gets price from DB if available" do
    db_price = 210

    Security::Price.create!(
      security: @security,
      date: Date.current,
      price: db_price
    )

    cache = Holding::PortfolioCache.new(@account)
    assert_equal db_price, cache.get_price(@security.id, Date.current).price
  end

  test "if no price from db, try getting the price from trades" do
    Security::Price.destroy_all

    cache = Holding::PortfolioCache.new(@account)
    assert_equal @trade.price, cache.get_price(@security.id, @trade.entry.date).price
  end

  test "a day's price from trades ignores the replay order" do
    Security::Price.destroy_all
    sale = create_trade(@security, account: @account, qty: -1, date: 1.day.ago.to_date, price: 220)
    purchase = create_trade(@security, account: @account, qty: 1, date: 1.day.ago.to_date, price: 215)
    Entry.where(id: [ sale.id, purchase.id ]).update_all(created_at: Time.zone.parse("2026-01-01 10:00:00"))
    Entry.where(id: sale.id).update_all(id: "00000000-0000-0000-0000-000000000001")
    Entry.where(id: purchase.id).update_all(id: "ffffffff-ffff-ffff-ffff-ffffffffffff")

    cache = Holding::PortfolioCache.new(@account)

    assert_equal "ffffffff-ffff-ffff-ffff-ffffffffffff", cache.get_trades(date: 1.day.ago.to_date).first.id
    assert_equal 220, cache.get_price(@security.id, 1.day.ago.to_date).price
  end

  test "if no price from db or trades, search holdings" do
    Security::Price.delete_all
    Entry.delete_all

    holding = Holding.create!(
      security: @security,
      account: @account,
      date: Date.current,
      qty: 1,
      price: 250,
      amount: 250 * 1,
      currency: "USD"
    )

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)
    assert_equal holding.price, cache.get_price(@security.id, holding.date).price
  end

  test "excludes income trades with zero price from trade price sources" do
    Security::Price.destroy_all

    @account.entries.create!(
      name: "Interest: TEST",
      date: Date.current,
      amount: -50,
      currency: "USD",
      entryable: Trade.new(
        qty: 0,
        security: @security,
        price: 0,
        currency: "USD",
        investment_activity_label: "Interest"
      )
    )

    cache = Holding::PortfolioCache.new(@account)

    # Income trade price=0 should be excluded; with no DB price for today,
    # get_price returns nil instead of 0.
    assert_nil cache.get_price(@security.id, Date.current)

    # The buy trade's price is still available on its own date.
    assert_equal @trade.price, cache.get_price(@security.id, @trade.entry.date).price
  end

  test "an internal movement at no price takes the latest earlier price instead of zero" do
    Security::Price.destroy_all
    create_movement(@security, qty: -0.5, date: 1.day.ago.to_date)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal @trade.price, cache.get_price(@security.id, 1.day.ago.to_date).price
  end

  test "a first entry moved at no price takes the latest earlier price when a holding is dated before the stored one" do
    @account = families(:empty).accounts.create!(name: "Transfers only", balance: 0, currency: "USD", accountable: Investment.new)
    moved_on = 5.days.ago.to_date
    Security::Price.delete_all
    Holding.create!(security: @security, account: @account, date: moved_on - 6, qty: 1, price: 30, amount: 30, currency: "USD")
    Security::Price.create!(security: @security, date: moved_on - 3, price: 40, currency: "USD")
    create_movement(@security, qty: 10, date: moved_on)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 40, cache.get_price(@security.id, moved_on).price
  end

  test "a stored price before the account's history outranks a holding price on the same day" do
    @account = families(:empty).accounts.create!(name: "Transfers only", balance: 0, currency: "USD", accountable: Investment.new)
    moved_on = 5.days.ago.to_date
    Security::Price.delete_all
    Holding.create!(security: @security, account: @account, date: moved_on - 3, qty: 1, price: 35, amount: 35, currency: "USD")
    Security::Price.create!(security: @security, date: moved_on - 3, price: 40, currency: "USD")
    create_movement(@security, qty: 10, date: moved_on)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 40, cache.get_price(@security.id, moved_on).price
  end

  test "a price filled in for a day moved at no price is found when its source is asked for" do
    Security::Price.delete_all
    Entry.delete_all
    Holding.create!(security: @security, account: @account, date: 1.day.ago.to_date, qty: 1, price: 50, amount: 50, currency: "USD")
    create_movement(@security, qty: 10, date: Date.current)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 50, cache.get_price(@security.id, Date.current, source: "holding").price
  end

  test "a first entry moved at no price takes the stored price from before the account's history" do
    @account = families(:empty).accounts.create!(name: "Transfers only", balance: 0, currency: "USD", accountable: Investment.new)
    moved_on = 5.days.ago.to_date
    Security::Price.delete_all
    Security::Price.create!(security: @security, date: moved_on - 3, price: 40, currency: "USD")
    Security::Price.create!(security: @security, date: moved_on + 2, price: 90, currency: "USD")
    create_movement(@security, qty: 10, date: moved_on)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 40, cache.get_price(@security.id, moved_on).price
  end

  test "a priced trade outranks an unpriced movement on the same day, whichever was recorded first" do
    Security::Price.destroy_all
    create_movement(@security, qty: 100, date: 1.day.ago.to_date)
    create_trade(@security, account: @account, qty: -40, date: 1.day.ago.to_date, price: 50)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 50, cache.get_price(@security.id, 1.day.ago.to_date).price
  end

  test "an unpriced movement with no earlier price takes the next one" do
    Security::Price.destroy_all
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal @trade.price, cache.get_price(@security.id, 3.days.ago.to_date).price
  end

  test "the price an unpriced movement takes is carried across a split" do
    Security::Price.destroy_all
    Security::Split.create!(security: @security, ex_date: 1.day.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    create_movement(@security, qty: 10, date: Date.current)
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal @trade.price / 2, cache.get_price(@security.id, Date.current).price
    assert_equal @trade.price, cache.get_price(@security.id, 3.days.ago.to_date).price, "no split between it and the next price"
  end

  test "the next price an unpriced movement takes is carried back across a split" do
    Security::Price.destroy_all
    Security::Split.create!(security: @security, ex_date: 2.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal @trade.price * 2, cache.get_price(@security.id, 3.days.ago.to_date).price, "a trade on the ex-date is in the new shares"
  end

  test "an unpriced movement keeps its zero when the security has no price at all" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 10, date: 1.day.ago.to_date)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 0, cache.get_price(@security.id, 1.day.ago.to_date).price, "the day still has a price, so its holding records the quantity"
  end

  test "a calculated holding at no price is not read back as a price" do
    Security::Price.destroy_all
    create_movement(@security, qty: 10, date: 1.day.ago.to_date)
    @account.holdings.create!(security: @security, date: 1.day.ago.to_date, qty: 11, price: 0, amount: 0, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal @trade.price, cache.get_price(@security.id, 1.day.ago.to_date).price
  end

  test "an unpriced movement takes no price from across a trade at no price" do
    Security::Price.destroy_all
    # A split booked as a trade: the new shares arrive at no price, and the
    # prices on either side of it are in different shares
    create_movement(@security, qty: 1, date: 1.day.ago.to_date, label: "Other")
    create_movement(@security, qty: 1, date: Date.current)
    create_movement(@security, qty: 1, date: 3.days.ago.to_date, label: "Other")
    create_movement(@security, qty: 1, date: 4.days.ago.to_date)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 0, cache.get_price(@security.id, Date.current).price, "not the price from before the split"
    assert_equal 0, cache.get_price(@security.id, 4.days.ago.to_date).price, "not the price from after it"
  end

  # SnapTrade books a STOCK_DIVIDEND as a Dividend trade at 0: the shares
  # arrive, and nobody observed a price.
  test "a stock dividend at no price takes the nearest price and does not block a later movement's" do
    Security::Price.destroy_all
    create_movement(@security, qty: 1, date: 1.day.ago.to_date, label: "Dividend")
    create_movement(@security, qty: 1, date: Date.current)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal @trade.price, cache.get_price(@security.id, 1.day.ago.to_date).price
    assert_equal @trade.price, cache.get_price(@security.id, Date.current).price
  end

  test "a reinvestment at no price takes the nearest price and does not block a later movement's" do
    Security::Price.destroy_all
    create_movement(@security, qty: 1, date: 1.day.ago.to_date, label: "Reinvestment")
    create_movement(@security, qty: 1, date: Date.current)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal @trade.price, cache.get_price(@security.id, 1.day.ago.to_date).price
    assert_equal @trade.price, cache.get_price(@security.id, Date.current).price
  end

  test "an unlabelled trade at no price stays a price, as it might be a split" do
    Security::Price.destroy_all
    create_movement(@security, qty: 1, date: 1.day.ago.to_date, label: nil)
    create_movement(@security, qty: 1, date: Date.current)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 0, cache.get_price(@security.id, Date.current).price
  end

  test "an earlier movement takes no price from across a possible split on a day that also has a quote" do
    Security::Price.destroy_all
    create_movement(@security, qty: 1, date: 4.days.ago.to_date)
    create_movement(@security, qty: 1, date: 3.days.ago.to_date, label: "Other")
    Security::Price.create!(security: @security, date: 3.days.ago.to_date, price: 100, currency: "USD")

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 0, cache.get_price(@security.id, 4.days.ago.to_date).price, "the quote may be in the shares after the split"
  end

  # A sale or an exchange at no price leaves the shares as they were.
  { "Sell" => "a sale", "Exchange" => "an exchange" }.each do |label, trade|
    test "an earlier movement takes the quote on a day with #{trade} at no price" do
      Security::Price.destroy_all
      create_movement(@security, qty: 1, date: 4.days.ago.to_date)
      create_movement(@security, qty: -1, date: 3.days.ago.to_date, label: label)
      Security::Price.create!(security: @security, date: 3.days.ago.to_date, price: 100, currency: "USD")

      cache = Holding::PortfolioCache.new(@account)

      assert_equal 100, cache.get_price(@security.id, 4.days.ago.to_date).price
    end
  end

  test "a future price is scaled back across a split before it, even one not yet in effect" do
    security = Security.create!(name: "Future Split", ticker: "FSPL", exchange_operating_mic: "TEST")
    create_movement(security, qty: 1, date: Date.current)
    create_trade(security, account: @account, qty: 1, date: 2.days.from_now.to_date, price: 50)
    Security::Split.create!(security: security, ex_date: 1.day.from_now.to_date, numerator: 2, denominator: 1, source: "manual")

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 100, cache.get_price(security.id, Date.current).price
  end

  test "converts historical prices using the requested date exchange rate" do
    account = families(:empty).accounts.create!(
      name: "CHF Brokerage",
      balance: 10000,
      currency: "CHF",
      accountable: Investment.new
    )
    holding_date = 2.days.ago.to_date

    ExchangeRate.create!(from_currency: "USD", to_currency: "CHF", date: holding_date, rate: 0.80)
    ExchangeRate.create!(from_currency: "USD", to_currency: "CHF", date: Date.current, rate: 0.95)

    Holding.create!(
      security: @security,
      account: account,
      date: holding_date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )

    Security::Price.create!(
      security: @security,
      date: holding_date,
      price: 100,
      currency: "USD"
    )

    cache = Holding::PortfolioCache.new(account, use_holdings: true)
    converted_price = cache.get_price(@security.id, holding_date)

    assert_equal BigDecimal("80.0"), converted_price.price
    assert_equal "CHF", converted_price.currency
  end

  private
    # Units moved in or out at no price, as a journal or a stock-plan deposit is
    # recorded, or under another label, as a split booked as a trade is
    def create_movement(security, qty:, date:, label: Trade::TRANSFER_LABEL)
      @account.entries.create!(
        name: label || "Trade",
        date: date,
        amount: 0,
        currency: "USD",
        entryable: Trade.new(qty: qty, security: security, price: 0, currency: "USD", investment_activity_label: label)
      )
    end
end
