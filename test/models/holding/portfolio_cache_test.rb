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
    provider_holding(@security, date: moved_on - 6, price: 30)
    Security::Price.create!(security: @security, date: moved_on - 3, price: 40, currency: "USD")
    create_movement(@security, qty: 10, date: moved_on)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 40, cache.get_price(@security.id, moved_on).price
  end

  test "a stored price before the account's history outranks a holding price on the same day" do
    @account = families(:empty).accounts.create!(name: "Transfers only", balance: 0, currency: "USD", accountable: Investment.new)
    moved_on = 5.days.ago.to_date
    Security::Price.delete_all
    provider_holding(@security, date: moved_on - 3, price: 35)
    Security::Price.create!(security: @security, date: moved_on - 3, price: 40, currency: "USD")
    create_movement(@security, qty: 10, date: moved_on)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 40, cache.get_price(@security.id, moved_on).price
  end

  test "a price filled in for a day moved at no price is found when its source is asked for" do
    Security::Price.delete_all
    Entry.delete_all
    provider_holding(@security, date: 1.day.ago.to_date, price: 50)
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

  test "an earlier movement takes the quote across a possible split when the split is recorded" do
    Security::Price.destroy_all
    create_movement(@security, qty: 1, date: 4.days.ago.to_date)
    create_movement(@security, qty: 1, date: 3.days.ago.to_date, label: "Other")
    Security::Price.create!(security: @security, date: 3.days.ago.to_date, price: 100, currency: "USD")
    Security::Split.create!(security: @security, ex_date: 3.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 200, cache.get_price(@security.id, 4.days.ago.to_date).price, "the quote is in the shares after the recorded split"
  end

  # On an earlier sync the movement's day took the next price, the only one
  # known then, and its calculated holding kept that price. A quote from
  # before it has arrived since.
  test "a price filled in for a movement on an earlier sync is worked out again from the prices known now" do
    Security::Price.destroy_all
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)
    @account.holdings.create!(security: @security, date: 3.days.ago.to_date, qty: 10, price: @trade.price, amount: @trade.price * 10, currency: "USD")
    Security::Price.create!(security: @security, date: 4.days.ago.to_date, price: 90, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 90, cache.get_price(@security.id, 3.days.ago.to_date).price
  end

  test "a later movement takes the quote from before a recorded split, not the zero of the trade booking it" do
    Security::Price.destroy_all
    Entry.delete_all
    Security::Price.create!(security: @security, date: 4.days.ago.to_date, price: 100, currency: "USD")
    create_movement(@security, qty: 1, date: 3.days.ago.to_date, label: "Other")
    Security::Split.create!(security: @security, ex_date: 3.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    create_movement(@security, qty: 1, date: 1.day.ago.to_date)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 50, cache.get_price(@security.id, 1.day.ago.to_date).price, "carried across the recorded split"
  end

  test "an earlier movement takes the provider's price on a recorded split's day, though the trade booking the split outranks it" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 1, date: 4.days.ago.to_date)
    create_movement(@security, qty: 1, date: 3.days.ago.to_date, label: "Other")
    Security::Split.create!(security: @security, ex_date: 3.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    provider_holding(@security, date: 3.days.ago.to_date, price: 100)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 200, cache.get_price(@security.id, 4.days.ago.to_date).price, "the provider's post-split price, carried back across the recorded split"
  end

  test "an earlier movement takes a priced trade on a recorded split's day, though the trade booking the split wins their tie" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 1, date: 4.days.ago.to_date)
    create_movement(@security, qty: 1, date: 3.days.ago.to_date, label: "Other")
    create_trade(@security, account: @account, qty: -1, date: 3.days.ago.to_date, price: 100)
    Security::Split.create!(security: @security, ex_date: 3.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")

    cache = Holding::PortfolioCache.new(@account)

    assert_equal 200, cache.get_price(@security.id, 4.days.ago.to_date).price, "the sale's post-split price, carried back across the recorded split"
  end

  # A calculated row is what an earlier sync derived from the prices known
  # then; a quote that arrived since must be able to replace it.
  test "a movement takes a quote over a later calculated holding priced on an earlier sync" do
    Security::Price.destroy_all
    Entry.delete_all
    @account.holdings.create!(security: @security, date: 2.days.ago.to_date, qty: 1, price: 80, amount: 80, currency: "USD")
    Security::Price.create!(security: @security, date: 3.days.ago.to_date, price: 90, currency: "USD")
    create_movement(@security, qty: 10, date: 1.day.ago.to_date)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 90, cache.get_price(@security.id, 1.day.ago.to_date).price
  end

  # Before the materializer cleans up, a calculated row can share a day with
  # the provider's snapshot in another currency; both rank the same.
  test "a movement takes the provider's snapshot over a calculated row on the same day" do
    Security::Price.destroy_all
    Entry.delete_all
    @account.holdings.create!(security: @security, date: 2.days.ago.to_date, qty: 1, price: 80, amount: 80, currency: "USD")
    provider_holding(@security, date: 2.days.ago.to_date, price: 120, currency: "CAD")
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: 1.day.ago.to_date, rate: 0.5)
    create_movement(@security, qty: 10, date: 1.day.ago.to_date)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 60, cache.get_price(@security.id, 1.day.ago.to_date).price, "the provider's 120 CAD, not the calculated 80 USD"
  end

  # The reverse calculator prices today from holdings alone.
  test "a calculated row passed over on a movement's day still answers a lookup for holding prices, at the day's price" do
    Security::Price.destroy_all
    Entry.delete_all
    @account.holdings.create!(security: @security, date: Date.current, qty: 10, price: 210, amount: 2100, currency: "USD")
    Security::Price.create!(security: @security, date: 1.day.ago.to_date, price: 90, currency: "USD")
    create_movement(@security, qty: 10, date: Date.current)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 90, cache.get_price(@security.id, Date.current, source: "holding")&.price, "today's price worked out again, not the row's 210"
  end

  test "a calculated row at no price passed over on a movement's day still answers a lookup for holding prices, at the day's price" do
    Security::Price.destroy_all
    Entry.delete_all
    @account.holdings.create!(security: @security, date: Date.current, qty: 10, price: 0, amount: 0, currency: "USD")
    Security::Price.create!(security: @security, date: 1.day.ago.to_date, price: 90, currency: "USD")
    create_movement(@security, qty: 10, date: Date.current)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 90, cache.get_price(@security.id, Date.current, source: "holding")&.price
  end

  # Each day after a movement up to the next price seen is filled in from the
  # movement's price; once a later sync prices the movement differently, those
  # rows are as out of date as the movement day's own.
  test "calculated rows after a movement priced again on a later sync give way to its new price" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)
    3.downto(0) { |n| @account.holdings.create!(security: @security, date: n.days.ago.to_date, qty: 10, price: 80, amount: 800, currency: "USD") }
    Security::Price.create!(security: @security, date: 4.days.ago.to_date, price: 90, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 90, cache.get_price(@security.id, 3.days.ago.to_date).price
    assert_nil cache.get_price(@security.id, 2.days.ago.to_date), "the earlier sync's 80 gives way, so the movement's price carries forward"
    assert_equal 90, cache.get_price(@security.id, Date.current, source: "holding")&.price, "today's holding price is the movement's new one"
  end

  test "today's holding price carried from a movement priced again follows a split in between" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)
    Security::Split.create!(security: @security, ex_date: 1.day.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    @account.holdings.create!(security: @security, date: Date.current, qty: 20, price: 40, amount: 800, currency: "USD")
    Security::Price.create!(security: @security, date: 4.days.ago.to_date, price: 90, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 45, cache.get_price(@security.id, Date.current, source: "holding")&.price, "the movement's 90, halved by the split"
  end

  test "the price carried past a movement starts again from the next price seen" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)
    create_trade(@security, account: @account, qty: 1, date: 1.day.ago.to_date, price: 100)
    @account.holdings.create!(security: @security, date: 2.days.ago.to_date, qty: 10, price: 80, amount: 800, currency: "USD")
    @account.holdings.create!(security: @security, date: Date.current, qty: 11, price: 100, amount: 1100, currency: "USD")
    Security::Price.create!(security: @security, date: 4.days.ago.to_date, price: 90, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_nil cache.get_price(@security.id, 2.days.ago.to_date), "between the movement and the sale: gives way"
    assert_equal 100, cache.get_price(@security.id, Date.current, source: "holding")&.price, "today's holding price carries the sale's"
  end

  # A quote for today can arrive between two runs on the same day.
  test "today's calculated row after a movement gives way to a quote for today" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 10, date: 3.days.ago.to_date)
    2.downto(0) { |n| @account.holdings.create!(security: @security, date: n.days.ago.to_date, qty: 10, price: 80, amount: 800, currency: "USD") }
    Security::Price.create!(security: @security, date: 4.days.ago.to_date, price: 80, currency: "USD")
    Security::Price.create!(security: @security, date: Date.current, price: 95, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 95, cache.get_price(@security.id, Date.current, source: "holding")&.price
  end

  # The first sync priced the movement from a later snapshot; a quote dated
  # between the two arrived since.
  test "calculated rows after a quote that arrived since give way to it" do
    Security::Price.destroy_all
    Entry.delete_all
    create_movement(@security, qty: 10, date: 4.days.ago.to_date)
    @account.holdings.create!(security: @security, date: 2.days.ago.to_date, qty: 10, price: 80, amount: 800, currency: "USD")
    provider_holding(@security, date: 1.day.ago.to_date, price: 80)
    Security::Price.create!(security: @security, date: 3.days.ago.to_date, price: 90, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 90, cache.get_price(@security.id, 4.days.ago.to_date).price
    assert_nil cache.get_price(@security.id, 2.days.ago.to_date), "the earlier sync's 80 gives way, so the 90 carries forward"
  end

  test "a provider row with no units is not a price" do
    Security::Price.destroy_all
    Entry.delete_all
    Security::Price.create!(security: @security, date: 5.days.ago.to_date, price: 90, currency: "USD")
    @provider_link ||= begin
      item = @account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      AccountProvider.create!(account: @account, provider: item.coinstats_accounts.create!(name: "Provider", currency: "USD"))
    end
    @account.holdings.create!(security: @security, date: 2.days.ago.to_date, qty: 0, price: 0, amount: 0, currency: "USD", account_provider: @provider_link)
    create_movement(@security, qty: 10, date: 1.day.ago.to_date)

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 90, cache.get_price(@security.id, 1.day.ago.to_date).price, "the stored 90, not the closure marker's 0"
  end

  # No movement that day: the row is passed over only for being at no price.
  test "a calculated row at no price still answers a lookup for holding prices, at the day's price or else its own" do
    Security::Price.destroy_all
    Entry.delete_all
    create_trade(@security, account: @account, qty: 1, date: 3.days.ago.to_date, price: 50)
    @account.holdings.create!(security: @security, date: Date.current, qty: 1, price: 0, amount: 0, currency: "USD")
    @account.holdings.create!(security: @security, date: 1.day.ago.to_date, qty: 1, price: 0, amount: 0, currency: "USD")
    Security::Price.create!(security: @security, date: Date.current, price: 70, currency: "USD")

    cache = Holding::PortfolioCache.new(@account, use_holdings: true)

    assert_equal 70, cache.get_price(@security.id, Date.current, source: "holding")&.price, "the day's price"
    assert_equal 0, cache.get_price(@security.id, 1.day.ago.to_date, source: "holding")&.price, "no other price that day: the row's own, as before"
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

  test "a price with a blank currency does not abort the calculation" do
    insert_blank_currency_price(date: Date.current, price: 210)

    cache = Holding::PortfolioCache.new(@account)

    assert_nil cache.get_price(@security.id, Date.current)
  end

  test "a price with a blank currency does not shadow a valid price on the same day" do
    insert_blank_currency_price(date: @trade.entry.date, price: 210)

    cache = Holding::PortfolioCache.new(@account)

    assert_equal @trade.price, cache.get_price(@security.id, @trade.entry.date).price
  end

  private
    def insert_blank_currency_price(date:, price:)
      Security::Price.insert_all([ {
        security_id: @security.id,
        date: date,
        price: price,
        currency: "",
        provisional: false,
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end

    # A holding the provider reported, not one a sync calculated
    def provider_holding(security, date:, price:, currency: "USD")
      @provider_link ||= begin
        item = @account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
        AccountProvider.create!(account: @account, provider: item.coinstats_accounts.create!(name: "Provider", currency: "USD"))
      end
      @account.holdings.create!(security: security, date: date, qty: 1, price: price, amount: price, currency: currency, account_provider: @provider_link)
    end

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
