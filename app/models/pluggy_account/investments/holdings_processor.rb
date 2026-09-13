# frozen_string_literal: true

class PluggyAccount::Investments::HoldingsProcessor
  include PluggyAccount::DataHelpers
  include PluggyAccount::Investments::DataHelpers

  def initialize(pluggy_account)
    @pluggy_account = pluggy_account
  end

  def process
    holdings = @pluggy_account.raw_holdings_payload || []
    return if holdings.blank?

    holdings.each do |holding_data|
      process_holding(holding_data.with_indifferent_access)
    rescue => e
      Rails.logger.error "PluggyAccount::Investments::HoldingsProcessor - #{e.class}: #{e.message}"
    end
  end

  private

    def account
      @pluggy_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_holding(data)
      # Pluggy uses `code`/`isin` for tickered securities. Fixed-income holdings
      # (CDB/LCI/LCA) carry neither, so fall back to the per-holding `id` as a
      # unique Security key -- their shared `name`/`issuer` would otherwise
      # collide and collapse the distinct positions into one.
      ticker = data[:code] || data[:isin] || data[:id]
      return if ticker.blank?

      security = resolve_security(ticker, data)
      return unless security

      quantity = parse_decimal(data[:quantity])

      # Pluggy never sends a `price` field. The per-unit price is `value`
      # (quantity * value == amount for both stocks and fixed-income). Keep
      # `price` as a defensive fallback for any future payload variant.
      price = parse_decimal(data[:value]) || parse_decimal(data[:price])
      return if quantity.nil? || price.nil?

      # Prefer the provider's reported total; fall back to quantity * price.
      amount = parse_decimal(data[:amount]) || (quantity * price)

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: (data[:currencyCode] || account.currency).to_s.upcase,
        date: Date.current,
        price: price,
        account_provider_id: @pluggy_account.account_provider&.id,
        source: "pluggy",
        delete_future_holdings: false
      )
    end
end
