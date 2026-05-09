# Port of PlaidAccount::Investments::SecurityResolver. Reads from
# provider_account.raw_holdings_payload and resolves Plaid securities to
# internal Security records via Security::Resolver (framework-level helper).
class Provider::Plaid::Investments::SecurityResolver
  UnresolvablePlaidSecurityError = Class.new(StandardError)

  def initialize(provider_account)
    @provider_account = provider_account
    @security_cache = {}
  end

  def resolve(plaid_security_id:)
    cached = @security_cache[plaid_security_id]
    return cached if cached.present?

    plaid_security = get_plaid_security(plaid_security_id)

    response = if plaid_security.nil?
      report_unresolvable_security(plaid_security_id)
      Response.new(security: nil, cash_equivalent?: false, brokerage_cash?: false)
    elsif brokerage_cash?(plaid_security)
      Response.new(security: nil, cash_equivalent?: true, brokerage_cash?: true)
    else
      security = Security::Resolver.new(
        plaid_security["ticker_symbol"],
        exchange_operating_mic: plaid_security["market_identifier_code"]
      ).resolve
      Response.new(
        security: security,
        cash_equivalent?: cash_equivalent?(plaid_security),
        brokerage_cash?: false
      )
    end

    @security_cache[plaid_security_id] = response
    response
  end

  private
    attr_reader :provider_account, :security_cache

    Response = Struct.new(:security, :cash_equivalent?, :brokerage_cash?, keyword_init: true)

    def securities
      provider_account.raw_holdings_payload&.dig("securities") || []
    end

    def get_plaid_security(plaid_security_id)
      direct = securities.find { |s| s["security_id"] == plaid_security_id && s["ticker_symbol"].present? }
      return direct if direct.present?
      securities.find { |s| s["proxy_security_id"] == plaid_security_id }
    end

    def report_unresolvable_security(plaid_security_id)
      Sentry.capture_exception(UnresolvablePlaidSecurityError.new("Could not resolve Plaid security from provided data")) do |scope|
        scope.set_context("plaid_security", { plaid_security_id: plaid_security_id })
      end
    end

    def known_plaid_brokerage_cash_tickers
      [ "CUR:USD" ]
    end

    def brokerage_cash?(plaid_security)
      return false unless plaid_security["ticker_symbol"].present?
      known_plaid_brokerage_cash_tickers.include?(plaid_security["ticker_symbol"])
    end

    def cash_equivalent?(plaid_security)
      return false unless plaid_security["type"].present?
      plaid_security["type"] == "cash" || plaid_security["is_cash_equivalent"] == true
    end
end
