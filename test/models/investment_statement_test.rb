require "test_helper"

class InvestmentStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    # families(:empty) defaults to currency "USD"
    @statement = InvestmentStatement.new(@family, user: nil)
  end

  test "portfolio_value and cash_balance with a single-currency family" do
    create_investment_account(balance: 1000, cash_balance: 100)

    assert_equal 1000, @statement.portfolio_value
    assert_equal 100, @statement.cash_balance
    assert_equal 900, @statement.holdings_value
  end

  test "portfolio_value converts foreign-currency accounts to family currency" do
    create_investment_account(balance: 1921.92, cash_balance: -162, currency: "USD")
    create_investment_account(balance: 1000, cash_balance: 1000, currency: "EUR")

    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.1
    )

    # 1921.92 + 1000 * 1.1 = 3021.92
    assert_in_delta 3021.92, @statement.portfolio_value, 0.001
    # -162 + 1000 * 1.1 = 938
    assert_in_delta 938, @statement.cash_balance, 0.001
    # 3021.92 - 938 = 2083.92
    assert_in_delta 2083.92, @statement.holdings_value, 0.001
  end

  test "portfolio_value falls back to 1:1 when FX rate is missing" do
    create_investment_account(balance: 1921.92, currency: "USD")
    create_investment_account(balance: 1000, currency: "EUR")

    # No ExchangeRate row → rates_for defaults to 1
    assert_in_delta 2921.92, @statement.portfolio_value, 0.001
  end

  test "current_holdings includes holdings from every investment account regardless of currency" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    assert_equal 2, @statement.current_holdings.count
  end

  test "top_holdings ranks by family-currency value across currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    # 2000 EUR = 2200 USD > 2100 USD, so ASML outranks AAPL in family currency
    top = @statement.top_holdings(limit: 2)
    assert_equal %w[ASML AAPL], top.map(&:ticker)
  end

  test "allocation weights sum to 100% with mixed currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    allocation = @statement.allocation
    assert_equal 2, allocation.size
    assert_in_delta 100.0, allocation.sum(&:weight), 0.01
    # Every row is labeled in family currency
    assert allocation.all? { |a| a.amount.currency.iso_code == "USD" }
  end

  private
    def create_investment_account(balance:, cash_balance: 0, currency: "USD")
      @family.accounts.create!(
        name: "Investment #{SecureRandom.hex(3)}",
        balance: balance,
        cash_balance: cash_balance,
        currency: currency,
        accountable: Investment.new
      )
    end
end
