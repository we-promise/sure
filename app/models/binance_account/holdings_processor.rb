class BinanceAccount::HoldingsProcessor
  def initialize(binance_account)
    @binance_account = binance_account
  end

  def process
    return unless account&.accountable_type == "Crypto"

    imported_external_ids = []

    Array(binance_account.raw_holdings_payload).each do |holding_data|
      quantity = decimal(holding_data["quantity"])
      next if quantity <= 0

      security = resolve_security(holding_data)
      next unless security

      external_id = "binance_#{binance_account.account_id}_#{holding_data['asset']}_#{Date.current}"
      imported_external_ids << external_id

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: decimal(holding_data["amount"]),
        currency: binance_account.currency,
        date: Date.current,
        price: decimal(holding_data["price"]),
        external_id: external_id,
        source: "binance",
        account_provider_id: binance_account.account_provider&.id,
        delete_future_holdings: false
      )
    end

    cleanup_stale_holdings(imported_external_ids)
  end

  private

    attr_reader :binance_account

    def account
      binance_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def resolve_security(holding_data)
      asset = holding_data["asset"].to_s.upcase
      ticker = asset.include?(":") ? asset : "CRYPTO:#{asset}"

      Security::Resolver.new(ticker).resolve
    rescue => e
      Rails.logger.warn(
        "BinanceAccount::HoldingsProcessor - Resolver failed for #{ticker}: #{e.class} - #{e.message}; creating offline security"
      )
      Security.find_or_initialize_by(ticker: ticker).tap do |security|
        security.offline = true if security.respond_to?(:offline=) && security.offline != true
        security.name = holding_data["name"] if security.name.blank?
        security.save! if security.changed?
      end
    end

    def cleanup_stale_holdings(imported_external_ids)
      return unless binance_account.account_provider&.id

      account.holdings
        .where(account_provider_id: binance_account.account_provider.id, date: Date.current)
        .where.not(external_id: imported_external_ids)
        .destroy_all
    end

    def decimal(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
end
