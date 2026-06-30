# frozen_string_literal: true

class QuestradeAccount::HoldingsProcessor
  include QuestradeAccount::DataHelpers

  def initialize(questrade_account)
    @questrade_account = questrade_account
  end

  def process
    return unless account.present?

    positions.each do |raw|
      process_holding(raw.with_indifferent_access)
    rescue => e
      Rails.logger.error "QuestradeAccount::HoldingsProcessor - Failed to process holding: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    end

    # Surface non-primary-currency cash as synthetic holdings.
    process_cash_holdings
  end

  private

    # Surface cash held in currencies other than the account's primary currency
    # as synthetic cash holdings (issue #1809). Primary-currency cash stays in
    # account.cash_balance.
    def process_cash_holdings
      @questrade_account.non_primary_cash_entries.each do |entry|
        amount = parse_decimal(entry[:amount])
        next if amount.nil?

        security = Security.cash_for(account, currency: entry[:currency])
        import_adapter.import_holding(
          security: security,
          quantity: amount,
          amount: amount,
          currency: entry[:currency],
          date: Date.current,
          price: 1,
          external_id: "questrade_cash_#{entry[:currency].to_s.downcase}",
          account_provider_id: @questrade_account.account_provider&.id,
          source: "questrade",
          delete_future_holdings: false
        )
      rescue => e
        Rails.logger.error "QuestradeAccount::HoldingsProcessor - Failed to import #{entry[:currency]} cash holding: #{e.message}"
      end
    end

    def account
      @questrade_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # raw_holdings_payload may be the array itself or the { positions: [...] }
    # hash returned by Provider::Questrade#get_holdings.
    def positions
      payload = @questrade_account.raw_holdings_payload
      payload = payload.with_indifferent_access[:positions] if payload.is_a?(Hash)
      Array(payload)
    end

    def process_holding(data)
      ticker = data[:symbol].to_s.strip
      return if ticker.blank?

      security = resolve_security(ticker, { name: ticker, currency: data[:currency] })
      return unless security

      quantity = parse_decimal(data[:openQuantity]) # may be fractional
      price = parse_decimal(data[:currentPrice])
      return if quantity.nil? || quantity.zero? || price.nil?

      # Prefer Questrade's authoritative market value; fall back to qty * price.
      amount = parse_decimal(data[:currentMarketValue]) || (quantity * price)
      cost_basis = parse_decimal(data[:averageEntryPrice]) # per-share cost

      # Questrade positions don't carry a currency, so we fall back to the
      # account currency. This is fine: Sure values each holding via the
      # security's own price/currency (Security#current_price), so this arg is
      # just a consistent bookkeeping/dedup key, not the source of valuation.
      currency = extract_currency(data, fallback: account.currency)
      date = Date.current
      external_id = [ "questrade", @questrade_account.questrade_account_id, data[:symbolId], date ].join("_")

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: amount,
        currency: currency,
        date: date,
        price: price,
        cost_basis: cost_basis,
        external_id: external_id,
        source: "questrade",
        account_provider_id: @questrade_account.account_provider&.id,
        delete_future_holdings: false
      )
    end
end
