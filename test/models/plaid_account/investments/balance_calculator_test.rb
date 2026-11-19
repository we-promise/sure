require "test_helper"

class PlaidAccount::Investments::BalanceCalculatorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)

    @plaid_account.update!(
      plaid_type: "investment",
      current_balance: 4000,
      available_balance: 2000 # We ignore this since we have current_balance + holdings
    )
  end

  test "calculates total balance from cash and positions" do
    brokerage_cash_security_id = "plaid_brokerage_cash" # Plaid's brokerage cash security
    cash_equivalent_security_id = "plaid_cash_equivalent" # Cash equivalent security (i.e. money market fund)
    aapl_security_id = "plaid_aapl_security" # Regular stock security

    test_investments = {
      transactions: [], # Irrelevant for balance calcs, leave empty
      holdings: [
        # $1,000 in brokerage cash
        {
          security_id: brokerage_cash_security_id,
          cost_basis: 1000,
          institution_price: 1,
          institution_value: 1000,
          quantity: 1000
        },
        # $1,000 in money market funds
        {
          security_id: cash_equivalent_security_id,
          cost_basis: 1000,
          institution_price: 1,
          institution_value: 1000,
          quantity: 1000
        },
        # $2,000 worth of AAPL stock
        {
          security_id: aapl_security_id,
          cost_basis: 2000,
          institution_price: 200,
          institution_value: 2000,
          quantity: 10
        }
      ],
      securities: [
        {
          security_id: brokerage_cash_security_id,
          ticker_symbol: "CUR:USD",
          is_cash_equivalent: true,
          type: "cash"
        },
        {
          security_id: cash_equivalent_security_id,
          ticker_symbol: "VMFXX", # Vanguard Money Market Reserves
          is_cash_equivalent: true,
          type: "mutual fund"
        },
        {
          security_id: aapl_security_id,
          ticker_symbol: "AAPL",
          is_cash_equivalent: false,
          type: "equity",
          market_identifier_code: "XNAS"
        }
      ]
    }

    @plaid_account.update!(raw_holdings_payload: test_investments)

    security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
    balance_calculator = PlaidAccount::Investments::BalanceCalculator.new(@plaid_account, security_resolver: security_resolver)

    # We set this equal to `current_balance`
    assert_equal 4000, balance_calculator.balance

    # This is the sum of "non-brokerage-cash-holdings".  In the above test case, this means
    # we're summing up $2,000 of AAPL + $1,000 Vanguard MM for $3,000 in holdings value.
    # We back this $3,000 from the $4,000 total to get $1,000 in cash balance.
    assert_equal 1000, balance_calculator.cash_balance
  end

  test "brokerage cash and imported holdings add up to the balance when a bond is quoted as a percent of par" do
    bond_security_id = "plaid_treasury_bond"

    @plaid_account.update!(
      current_balance: 10112,
      raw_holdings_payload: {
        transactions: [],
        holdings: [
          {
            security_id: bond_security_id,
            institution_price: 91.12,
            institution_value: 9112,
            institution_price_as_of: Date.current,
            quantity: 10000,
            iso_currency_code: "USD"
          }
        ],
        securities: [
          {
            security_id: bond_security_id,
            ticker_symbol: nil,
            name: "US Treasury Note",
            is_cash_equivalent: false,
            type: "fixed income"
          }
        ]
      }
    )

    security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
    security_resolver.stubs(:resolve).returns(
      OpenStruct.new(security: securities(:aapl), brokerage_cash?: false)
    )

    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: security_resolver).process
    cash_balance = PlaidAccount::Investments::BalanceCalculator.new(@plaid_account, security_resolver: security_resolver).cash_balance
    imported_holdings_value = @plaid_account.current_account.holdings.where(date: Date.current).sum(:amount)

    assert_equal 1000, cash_balance
    assert_equal 10112, imported_holdings_value + cash_balance
  end

  test "brokerage cash and imported holdings add up to the balance when a holding has no price" do
    @plaid_account.update!(
      current_balance: 1500,
      raw_holdings_payload: {
        transactions: [],
        holdings: [
          {
            security_id: "valued_without_price",
            institution_price: nil,
            institution_value: 1000,
            quantity: 10,
            iso_currency_code: "USD"
          },
          {
            security_id: "no_price_or_value",
            institution_price: nil,
            institution_value: nil,
            quantity: 5,
            iso_currency_code: "USD"
          }
        ],
        securities: []
      }
    )

    security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
    security_resolver.stubs(:resolve).with(plaid_security_id: "valued_without_price").returns(
      OpenStruct.new(security: securities(:aapl), brokerage_cash?: false)
    )
    security_resolver.stubs(:resolve).with(plaid_security_id: "no_price_or_value").returns(
      OpenStruct.new(security: securities(:msft), brokerage_cash?: false)
    )

    PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: security_resolver).process
    cash_balance = PlaidAccount::Investments::BalanceCalculator.new(@plaid_account, security_resolver: security_resolver).cash_balance
    imported_holdings = @plaid_account.current_account.holdings.where(date: Date.current)

    assert_equal [ securities(:aapl) ], imported_holdings.map(&:security)
    assert_equal 100, imported_holdings.first.price
    assert_equal 500, cash_balance
    assert_equal 1500, imported_holdings.sum(:amount) + cash_balance
  end
end
