# Port of PlaidAccount::Investments::BalanceCalculator. Reads balance fields
# from provider_account.raw_payload (which mirrors what Plaid returns from
# /accounts/get) instead of denormalised columns on plaid_accounts.
class Provider::Plaid::Investments::BalanceCalculator
  NegativeCashBalanceError = Class.new(StandardError)
  NegativeTotalValueError  = Class.new(StandardError)

  def initialize(provider_account, security_resolver:)
    @provider_account = provider_account
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

  # Plaid bundles "brokerage cash" + "cash-equivalent holdings" into reported
  # balance; Sure separates "brokerage cash" (account.cash_balance) from
  # "invested holdings" (account.balance - cash_balance). See SecurityResolver.
  def cash_balance
    bal = calculate_investment_brokerage_cash
    if bal.negative?
      Sentry.capture_exception(
        NegativeCashBalanceError.new("Cash balance is negative for plaid investment account"),
        level: :warning
      )
    end
    bal
  end

  private
    attr_reader :provider_account, :security_resolver

    def holdings
      provider_account.raw_holdings_payload&.dig("holdings") || []
    end

    def calculate_investment_brokerage_cash
      total_investment_account_value - true_holdings_value
    end

    def total_investment_account_value
      balances = provider_account.raw_payload&.dig("balances") || {}
      balances["current"] || balances["available"] || 0
    end

    def true_holdings_value
      true_holdings = holdings.reject do |h|
        result = security_resolver.resolve(plaid_security_id: h["security_id"])
        result.brokerage_cash?
      end
      true_holdings.sum { |h| h["quantity"] * h["institution_price"] }
    end
end
