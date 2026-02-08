# Processes Coinbase account data to create/update Holdings records.
# Each Coinbase wallet is a single holding of one cryptocurrency.
class CoinbaseAccount::HoldingsProcessor
  def initialize(coinbase_account)
    @coinbase_account = coinbase_account
  end

  def process
    Rails.logger.info(
      "CoinbaseAccount::HoldingsProcessor - Processing coinbase_account #{coinbase_account.id}: " \
      "account=#{account&.id || 'nil'} accountable_type=#{account&.accountable_type || 'nil'} " \
      "quantity=#{quantity} crypto=#{crypto_code}"
    )

    unless account&.accountable_type == "Crypto"
      Rails.logger.info("CoinbaseAccount::HoldingsProcessor - Skipping: not a Crypto account")
      return
    end

    if quantity.zero?
      Rails.logger.info("CoinbaseAccount::HoldingsProcessor - Skipping: quantity is zero")
      return
    end

    # Resolve the security for this cryptocurrency
    security = resolve_security
    unless security
      Rails.logger.warn("CoinbaseAccount::HoldingsProcessor - Skipping: could not resolve security for #{crypto_code}")
      return
    end

    # Get price from market data or calculate from native_balance if available
    current_price = fetch_current_price || 0
    amount = calculate_amount(current_price)

    Rails.logger.info(
      "CoinbaseAccount::HoldingsProcessor - Importing holding for #{coinbase_account.id}: " \
      "#{quantity} #{crypto_code} @ #{current_price} = #{amount} #{native_currency}"
    )

    # Import the holding using the adapter
    # Use native currency from Coinbase (USD, EUR, GBP, etc.)
    holding = import_adapter.import_holding(
      security: security,
      quantity: quantity,
      amount: amount,
      currency: native_currency,
      date: Date.current,
      price: current_price,
      cost_basis: nil, # Coinbase doesn't provide cost basis in basic API
      external_id: "coinbase_#{coinbase_account.account_id}_#{Date.current}",
      account_provider_id: coinbase_account.account_provider&.id,
      source: "coinbase",
      delete_future_holdings: false
    )

    Rails.logger.info(
      "CoinbaseAccount::HoldingsProcessor - Saved holding id=#{holding.id} " \
      "security=#{holding.security_id} qty=#{holding.qty}"
    )

    holding
  rescue => e
    Rails.logger.error("CoinbaseAccount::HoldingsProcessor - Error: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    nil
  end

  private

    attr_reader :coinbase_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      coinbase_account.current_account
    end

    def quantity
      @quantity ||= (coinbase_account.current_balance || 0).to_d
    end

    def crypto_code
      @crypto_code ||= coinbase_account.currency.to_s.upcase
    end

    def native_currency
      # Get native currency from Coinbase (USD, EUR, GBP, etc.) or fall back to account currency
      @native_currency ||= coinbase_account.raw_payload&.dig("native_balance", "currency") ||
                           account&.currency ||
                           "USD"
    end

    def resolve_security
      # Use CRYPTO: prefix to distinguish from stock tickers
      # This matches SimpleFIN's handling of crypto assets
      ticker = crypto_code.include?(":") ? crypto_code : "CRYPTO:#{crypto_code}"

      # Try to resolve via Security::Resolver first
      begin
        Security::Resolver.new(ticker).resolve
      rescue => e
        Rails.logger.warn(
          "CoinbaseAccount::HoldingsProcessor - Resolver failed for #{ticker}: " \
          "#{e.class} - #{e.message}; creating offline security"
        )
        # Fall back to creating an offline security
        Security.find_or_initialize_by(ticker: ticker).tap do |sec|
          sec.offline = true if sec.respond_to?(:offline=) && sec.offline != true
          sec.name = crypto_name if sec.name.blank?
          sec.exchange_operating_mic = "XCBS" # Coinbase exchange MIC
          sec.save! if sec.changed?
        end
      end
    end

    def crypto_name
      # Try to get the full name from institution_metadata
      coinbase_account.institution_metadata&.dig("crypto_name") ||
        coinbase_account.raw_payload&.dig("currency", "name") ||
        crypto_code
    end

    def fetch_current_price
      # Try to get price from Coinbase's native_balance (USD equivalent) if available
      native_amount = coinbase_account.raw_payload&.dig("native_balance", "amount")
      if native_amount.present? && quantity > 0
        return (native_amount.to_d / quantity).round(8)
      end

      # Fetch spot price from Coinbase API in native currency
      provider = coinbase_provider
      if provider
        spot_data = provider.get_spot_price("#{crypto_code}-#{native_currency}")
        if spot_data && spot_data["amount"].present?
          price = spot_data["amount"].to_d
          Rails.logger.info(
            "CoinbaseAccount::HoldingsProcessor - Fetched spot price for #{crypto_code}: #{price} #{native_currency}"
          )
          return price
        end
      end

      # Fall back to Security's latest price if available
      if (security = resolve_security)
        latest_price = security.prices.order(date: :desc).first
        return latest_price.price if latest_price.present?
      end

      # If no price available, return nil
      Rails.logger.warn("CoinbaseAccount::HoldingsProcessor - No price available for #{crypto_code}")
      nil
    end

    def coinbase_provider
      coinbase_account.coinbase_item&.coinbase_provider
    end

    def calculate_amount(price)
      return 0 unless price && price > 0

      (quantity * price).round(2)
    end
end
