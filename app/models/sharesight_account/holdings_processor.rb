class SharesightAccount::HoldingsProcessor
  include SharesightAccount::DataHelpers

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
  end

  def process
    return unless account.present?

    Array(@sharesight_account.raw_holdings_payload).each do |holding|
      process_holding(holding)
    end
  end

  private

    def account
      @sharesight_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def portfolio_currency
      @sharesight_account.currency
    end

    def process_holding(holding)
      instrument = holding["instrument"] || {}
      quantity = parse_decimal(holding["quantity"])
      # Sold holdings come back with no units, and "limited" ones (hidden on
      # cheaper plans) have no numbers at all.
      return if quantity.nil?
      return if holding["limited"]

      security = resolve_security(instrument["code"], instrument["market_code"], instrument["name"])
      return unless security

      date = Date.current
      external_id = "sharesight_holding_#{@sharesight_account.sharesight_account_id}_#{holding['id']}_#{date}"

      if quantity.zero?
        # A fully sold position still needs a row for today. Without one, the
        # previous day's row stays the latest snapshot and the sold position
        # keeps showing in current holdings. A zero-quantity row is filtered
        # out there, and it updates the morning row when the sale lands the
        # same day, since the external id includes the date.
        import_adapter.import_holding(
          security: security,
          quantity: BigDecimal("0"),
          amount: BigDecimal("0"),
          currency: @sharesight_account.holding_currencies[holding["id"].to_s] || portfolio_currency,
          date: date,
          price: parse_decimal(holding["instrument_price"]) || BigDecimal("0"),
          external_id: external_id,
          source: "sharesight",
          account_provider_id: @sharesight_account.account_provider&.id,
          delete_future_holdings: false
        )
        return
      end

      return unless quantity.positive?

      currency, price = holding_price(holding, quantity)
      return unless price

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * price,
        currency: currency,
        date: date,
        price: price,
        external_id: external_id,
        source: "sharesight",
        account_provider_id: @sharesight_account.account_provider&.id,
        delete_future_holdings: false
      )
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "SharesightAccount::HoldingsProcessor - Failed to process holding #{holding['id']}: #{e.message}",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight",
        metadata: { holding_id: holding["id"], sharesight_account_id: @sharesight_account.id }
      )
    end

    # Use the instrument's own price and currency when we have both, otherwise
    # the holding's value per unit in the portfolio's currency.
    def holding_price(holding, quantity)
      price = parse_decimal(holding["instrument_price"])
      currency = @sharesight_account.holding_currencies[holding["id"].to_s]
      return [ currency, price ] if currency && price

      value = parse_decimal(holding["value"])
      return [ portfolio_currency, value / quantity ] if value

      [ portfolio_currency, price ]
    end
end
