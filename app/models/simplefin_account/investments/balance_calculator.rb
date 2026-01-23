# SimpleFin Investment balance calculator
# SimpleFin provides clear balance and holdings data, so calculations are simpler than Plaid
class SimplefinAccount::Investments::BalanceCalculator
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def balance
    # SimpleFin provides direct balance data
    simplefin_account.current_balance || BigDecimal("0")
  end

  def cash_balance
    # Calculate cash balance as total balance minus non-cash holdings value
    # Money market funds are treated as cash equivalents (settlement funds)
    total_balance = balance
    non_cash_value = non_cash_holdings_value

    cash = total_balance - non_cash_value

    # Allow negative cash to represent margin debt (matching Plaid's approach)
    # Log a warning for debugging, but don't clamp to zero
    if cash.negative?
      Rails.logger.info("SimpleFin: negative cash_balance (#{cash}) for account #{simplefin_account.account_id || simplefin_account.id} - may indicate margin usage or stale data")
    end

    cash
  end

  private
    attr_reader :simplefin_account

    def holdings_data
      @holdings_data ||= simplefin_account.raw_holdings_payload.presence ||
                         simplefin_account.raw_payload&.dig("holdings") ||
                         []
    end

    def non_cash_holdings_value
      return BigDecimal("0") unless holdings_data.present?

      holdings_data.sum do |holding|
        # Skip money market funds - they're cash equivalents
        next BigDecimal("0") if cash_equivalent?(holding)

        parse_market_value(holding["market_value"])
      end
    end

    def cash_equivalent?(holding)
      symbol = holding["symbol"].to_s.upcase.strip
      description = holding["description"].to_s

      # Check known money market tickers (configured in config/initializers/simplefin.rb)
      return true if money_market_tickers.include?(symbol)

      # Check description patterns
      money_market_patterns.any? { |pattern| description.match?(pattern) }
    end

    def money_market_tickers
      Rails.configuration.x.simplefin.money_market_tickers || []
    end

    def money_market_patterns
      Rails.configuration.x.simplefin.money_market_patterns || []
    end

    def parse_market_value(market_value)
      case market_value
      when String
        BigDecimal(market_value)
      when Numeric
        BigDecimal(market_value.to_s)
      else
        BigDecimal("0")
      end
    rescue ArgumentError => e
      Rails.logger.warn "SimpleFin holdings market_value parse error for account #{simplefin_account.account_id || simplefin_account.id}: #{e.message} (value: #{market_value.inspect})"
      BigDecimal("0")
    end
end
