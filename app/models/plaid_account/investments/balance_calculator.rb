# Plaid Investment balances have a ton of edge cases.  This processor is responsible
# for deriving "brokerage cash" vs. "total value" based on Plaid's reported balances and holdings.
class PlaidAccount::Investments::BalanceCalculator
  NegativeCashBalanceError = Class.new(StandardError)
  NegativeTotalValueError = Class.new(StandardError)

  # How close cash-by-subtraction has to land to zero before we treat the
  # institution as one that reports positions and cash separately.  Holdings
  # values arrive as JSON floats, so exact equality is not safe.
  CASH_DERIVATION_TOLERANCE = 0.01

  def initialize(plaid_account, security_resolver:)
    @plaid_account = plaid_account
    @security_resolver = security_resolver
  end

  def balance
    total_value = total_investment_account_value

    if total_value.negative?
      Sentry.capture_exception(
        NegativeTotalValueError.new("Total value is negative for plaid investment account"),
        level: :warning
      )
    end

    total_value
  end

  # Plaid considers "brokerage cash" and "cash equivalent holdings" to all be part of "cash balance"
  #
  # Internally, we DO NOT.  Sure clearly distinguishes between "brokerage cash" vs. "holdings (i.e. invested cash)"
  # For this reason, we must manually calculate the cash balance based on "total value" and "holdings value"
  # See PlaidAccount::Investments::SecurityResolver for more details.
  def cash_balance
    cash_balance = calculate_investment_brokerage_cash

    if cash_balance.negative?
      Sentry.capture_exception(
        NegativeCashBalanceError.new("Cash balance is negative for plaid investment account"),
        level: :warning
      )
    end

    cash_balance
  end

  private
    attr_reader :plaid_account, :security_resolver

    def holdings
      plaid_account.raw_holdings_payload&.dig("holdings") || []
    end

    def calculate_investment_brokerage_cash
      total_investment_account_value - true_holdings_value
    end

    # Plaid guarantees `current_balance` AND/OR `available_balance` is always present, and based on the
    # docs, `current_balance` should represent "total account value".  Most institutions report it that
    # way and we take it as our source of truth.
    #
    # Some do not.  They report only the value of the positions in `current_balance` - or zero - and put
    # the brokerage cash in `available_balance`, without sending a cash-equivalent holding either.  The
    # cash then disappears: subtracting the holdings from `current_balance` lands on zero, so
    # `cash_balance` reports nothing held and the account is understated by the whole cash amount.
    #
    # The tell is that zero arriving alongside an institution that still reports available cash - one
    # that genuinely held none would report none.  Adding the two unconditionally is not an option: it
    # would double-count every institution that already includes cash in `current_balance`.
    def total_investment_account_value
      reported_total = plaid_account.current_balance

      return plaid_account.available_balance if reported_total.nil?

      available = plaid_account.available_balance

      return reported_total unless available.present? && available.positive?

      # Zero is the same report with nothing in the positions, so the holdings
      # have to be added back rather than subtracted from: taking zero as the
      # total would value the positions at nothing and derive negative cash.
      return true_holdings_value + available if reported_total.zero?

      return reported_total unless cash_derives_to_zero?(reported_total)

      reported_total + available
    end

    def cash_derives_to_zero?(reported_total)
      (reported_total - true_holdings_value).abs < CASH_DERIVATION_TOLERANCE
    end

    # Plaid holdings summed up, LESS "brokerage cash" holdings (that we've manually identified)
    def true_holdings_value
      # True holdings are holdings *less* Plaid's "pseudo-securities" (e.g. `CUR:USD` brokerage cash "holding")
      true_holdings = holdings.reject do |h|
        security = security_resolver.resolve(plaid_security_id: h["security_id"])
        security.brokerage_cash?
      end

      true_holdings.sum { |h| h["quantity"] * h["institution_price"] }
    end
end
