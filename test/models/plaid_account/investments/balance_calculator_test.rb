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

  test "adds available cash when the institution reports only positions in current balance" do
    aapl_security_id = "plaid_aapl_security"

    # Some brokerages report the value of the positions in `current_balance` and keep the
    # brokerage cash in `available_balance`, sending no cash-equivalent holding at all.
    @plaid_account.update!(
      current_balance: 4000,
      available_balance: 1500,
      raw_holdings_payload: {
        transactions: [],
        holdings: [
          {
            security_id: aapl_security_id,
            cost_basis: 4000,
            institution_price: 200,
            institution_value: 4000,
            quantity: 20
          }
        ],
        securities: [
          {
            security_id: aapl_security_id,
            ticker_symbol: "AAPL",
            is_cash_equivalent: false,
            type: "equity",
            market_identifier_code: "XNAS"
          }
        ]
      }
    )

    balance_calculator = build_calculator

    assert_equal 5500, balance_calculator.balance
    assert_equal 1500, balance_calculator.cash_balance
  end

  test "uses available cash when the institution reports a zero current balance" do
    # The same brokerages report zero rather than the positions when the account holds
    # nothing but cash.  Zero is not nil, so it was taken as the total account value.
    @plaid_account.update!(
      current_balance: 0,
      available_balance: 2500,
      raw_holdings_payload: { transactions: [], holdings: [], securities: [] }
    )

    balance_calculator = build_calculator

    assert_equal 2500, balance_calculator.balance
    assert_equal 2500, balance_calculator.cash_balance
  end

  test "leaves a fully invested account alone when no cash is available" do
    aapl_security_id = "plaid_aapl_security"

    # Guards the case above: holdings equal the total here too, but the institution
    # reports no available cash, so there is nothing to add and nothing to fix.
    @plaid_account.update!(
      current_balance: 3000,
      available_balance: 0,
      raw_holdings_payload: {
        transactions: [],
        holdings: [
          {
            security_id: aapl_security_id,
            cost_basis: 3000,
            institution_price: 200,
            institution_value: 3000,
            quantity: 15
          }
        ],
        securities: [
          {
            security_id: aapl_security_id,
            ticker_symbol: "AAPL",
            is_cash_equivalent: false,
            type: "equity",
            market_identifier_code: "XNAS"
          }
        ]
      }
    )

    balance_calculator = build_calculator

    assert_equal 3000, balance_calculator.balance
    assert_equal 0, balance_calculator.cash_balance
  end

  test "adds positions back when the institution reports zero with holdings present" do
    aapl_security_id = "plaid_aapl_security"

    # The same zero report, but the account is not empty. Taking zero as the
    # total would value the positions at nothing and derive negative cash.
    @plaid_account.update!(
      current_balance: 0,
      available_balance: 1500,
      raw_holdings_payload: {
        transactions: [],
        holdings: [
          {
            security_id: aapl_security_id,
            cost_basis: 4000,
            institution_price: 200,
            institution_value: 4000,
            quantity: 20
          }
        ],
        securities: [
          {
            security_id: aapl_security_id,
            ticker_symbol: "AAPL",
            is_cash_equivalent: false,
            type: "equity",
            market_identifier_code: "XNAS"
          }
        ]
      }
    )

    balance_calculator = build_calculator

    assert_equal 5500, balance_calculator.balance
    assert_equal 1500, balance_calculator.cash_balance
  end

  test "leaves an account carrying a margin loan alone" do
    aapl_security_id = "plaid_aapl_security"

    # Plaid reports borrowed funds separately, so a positive margin loan is the
    # signal that `available` may be buying power rather than settled cash.
    # Without this the shape below reads exactly like the case above.
    @plaid_account.update!(
      current_balance: 4000,
      available_balance: 8000,
      raw_payload: { "balances" => { "margin_loan_amount" => 2500 } },
      raw_holdings_payload: {
        transactions: [],
        holdings: [
          {
            security_id: aapl_security_id,
            cost_basis: 4000,
            institution_price: 200,
            institution_value: 4000,
            quantity: 20
          }
        ],
        securities: [
          {
            security_id: aapl_security_id,
            ticker_symbol: "AAPL",
            is_cash_equivalent: false,
            type: "equity",
            market_identifier_code: "XNAS"
          }
        ]
      }
    )

    balance_calculator = build_calculator

    assert_equal 4000, balance_calculator.balance
    assert_equal 0, balance_calculator.cash_balance
  end

  private
    def build_calculator
      security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
      PlaidAccount::Investments::BalanceCalculator.new(@plaid_account, security_resolver: security_resolver)
    end
end
