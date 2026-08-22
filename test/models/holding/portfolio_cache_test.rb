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

  test "preserves native price currency instead of converting to account currency" do
    account = families(:empty).accounts.create!(
      name: "CAD Brokerage",
      balance: 10000,
      currency: "CAD",
      accountable: Investment.new
    )
    holding_date = 2.days.ago.to_date

    ExchangeRate.create!(from_currency: "USD", to_currency: "CAD", date: holding_date, rate: 1.35)

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
    price = cache.get_price(@security.id, holding_date)

    assert_equal BigDecimal("100.0"), price.price
    assert_equal "USD", price.currency
  end

  test "picks account currency deterministically when same-date DB prices tie" do
    account = families(:empty).accounts.create!(
      name: "USD Brokerage",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )
    date = Date.current

    create_trade(@security, account: account, qty: 1, date: date - 1.day, price: 1)
    Security::Price.create!(security: @security, date: date, price: 90, currency: "EUR")
    Security::Price.create!(security: @security, date: date, price: 100, currency: "USD")

    cache = Holding::PortfolioCache.new(account)
    price = cache.get_price(@security.id, date)

    assert_equal "USD", price.currency
    assert_equal BigDecimal("100"), price.price
  end

  test "prefers security's dominant currency over alphabetical when account currency absent" do
    account = families(:empty).accounts.create!(
      name: "CAD Brokerage Dual Prices",
      balance: 10000,
      currency: "CAD",
      accountable: Investment.new
    )
    date = Date.current

    create_trade(@security, account: account, qty: 1, date: date - 3.days, price: 1)
    # More USD observations than EUR → USD is the security's preferred currency
    # even though EUR sorts first alphabetically.
    Security::Price.create!(security: @security, date: date - 1.day, price: 95, currency: "USD")
    Security::Price.create!(security: @security, date: date - 2.days, price: 94, currency: "USD")
    Security::Price.create!(security: @security, date: date, price: 90, currency: "EUR")
    Security::Price.create!(security: @security, date: date, price: 100, currency: "USD")

    cache = Holding::PortfolioCache.new(account)
    price = cache.get_price(@security.id, date)

    assert_equal "USD", price.currency
    assert_equal BigDecimal("100"), price.price
  end

  test "excludes neutralized manual holdings from holding price sources" do
    account = families(:empty).accounts.create!(
      name: "CAD Brokerage Neutralized",
      balance: 10000,
      currency: "CAD",
      accountable: Investment.new
    )
    date = Date.current

    create_trade(@security, account: account, qty: 1, date: date - 5.days, price: 1)
    Security::Price.destroy_all

    Holding.create!(
      security: @security,
      account: account,
      date: date,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )

    Holding.create!(
      security: @security,
      account: account,
      date: date,
      qty: 0,
      price: 95,
      amount: 0,
      currency: "CAD",
      cost_basis_source: "manual",
      cost_basis_locked: true
    )

    cache = Holding::PortfolioCache.new(account, use_holdings: true)
    price = cache.get_price(@security.id, date)

    assert_equal "USD", price.currency
    assert_equal BigDecimal("100"), price.price
  end

  test "includes sold-out calculated holdings as holding price sources" do
    account = families(:empty).accounts.create!(
      name: "Sold Out Position",
      balance: 10000,
      currency: "USD",
      accountable: Investment.new
    )
    date = Date.current

    create_trade(@security, account: account, qty: 1, date: date - 5.days, price: 1)
    Security::Price.destroy_all
    Entry.where("date >= ?", date).delete_all

    Holding.create!(
      security: @security,
      account: account,
      date: date,
      qty: 0,
      price: 250,
      amount: 0,
      currency: "USD"
    )

    cache = Holding::PortfolioCache.new(account, use_holdings: true)
    price = cache.get_price(@security.id, date)

    assert_equal BigDecimal("250"), price.price
    assert_equal "USD", price.currency
  end
end
