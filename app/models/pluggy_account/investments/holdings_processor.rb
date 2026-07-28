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
      ticker = data[:code] || data[:isin]
      return if ticker.blank?

      security = resolve_security(ticker, data)
      return unless security

      quantity = parse_decimal(data[:quantity])
      price = parse_decimal(data[:price])
      return if quantity.nil? || price.nil?

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * price,
        currency: (data[:currencyCode] || account.currency).to_s.upcase,
        date: Date.current,
        price: price,
        account_provider_id: @pluggy_account.account_provider&.id,
        source: "pluggy",
        delete_future_holdings: false
      )
    end
end
