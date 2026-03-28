class KrakenAccount::HoldingsProcessor
  def initialize(kraken_account)
    @kraken_account = kraken_account
  end

  def process
    return unless account&.accountable_type == "Crypto"
    return if quantity.zero? || fiat_asset?

    security = resolve_security
    return unless security

    current_price = fetch_current_price
    return unless current_price.present? && current_price.positive?

    import_adapter.import_holding(
      security: security,
      quantity: quantity,
      amount: (quantity * current_price).round(2),
      currency: native_currency,
      date: Date.current,
      price: current_price,
      cost_basis: nil,
      external_id: "kraken_#{kraken_account.account_id}_#{Date.current}",
      account_provider_id: kraken_account.account_provider&.id,
      source: "kraken",
      delete_future_holdings: false
    )
  rescue => e
    Rails.logger.error("KrakenAccount::HoldingsProcessor - Error for #{kraken_account.id}: #{e.class} - #{e.message}")
    nil
  end

  private

    attr_reader :kraken_account

    def account
      kraken_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def quantity
      @quantity ||= (kraken_account.current_balance || 0).to_d
    end

    def asset_code
      @asset_code ||= kraken_account.currency.to_s.upcase
    end

    def native_currency
      @native_currency ||= kraken_account.raw_payload&.dig("native_balance", "currency") || account&.currency || "USD"
    end

    def fiat_asset?
      ActiveModel::Type::Boolean.new.cast(kraken_account.raw_payload&.dig("fiat_asset"))
    end

    def resolve_security
      ticker = asset_code.include?(":") ? asset_code : "CRYPTO:#{asset_code}"

      Security::Resolver.new(ticker).resolve
    rescue => e
      Rails.logger.warn(
        "KrakenAccount::HoldingsProcessor - Resolver failed for #{ticker}: #{e.class} - #{e.message}; creating offline security"
      )

      Security.find_or_initialize_by(ticker: ticker).tap do |security|
        security.offline = true if security.respond_to?(:offline=) && security.offline != true
        security.name = kraken_account.institution_metadata&.dig("asset_name") || asset_code if security.name.blank?
        security.save! if security.changed?
      end
    end

    def fetch_current_price
      raw_price = kraken_account.raw_payload&.dig("native_balance", "price")
      return raw_price.to_d if raw_price.present?

      provider = kraken_account.kraken_item&.kraken_provider
      return provider.get_spot_price(asset: asset_code, quote_currency: native_currency) if provider

      latest_price = resolve_security&.prices&.order(date: :desc)&.first
      latest_price&.price
    end
end
