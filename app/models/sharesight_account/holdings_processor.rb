class SharesightAccount::HoldingsProcessor
  include SharesightAccount::DataHelpers

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
  end

  def process
    return unless account.present?

    # What current holdings showed before this run.
    @last_snapshot_date = account.latest_provider_holdings_snapshot_date

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
      return if quantity.negative?

      security = resolve_security(instrument["code"], instrument["market_code"], instrument["name"])
      return unless security

      currency, price = holding_price(holding, quantity)
      return unless price

      # A sold position current holdings still shows gets a zero row for today,
      # so it drops out (one from earlier today is updated, since the external
      # id has the date in it). Anything sold before that is skipped, or every
      # sync would add a row for positions sold long ago.
      return if quantity.zero? && !still_held?(security)

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * price,
        currency: currency,
        date: Date.current,
        price: price,
        external_id: "sharesight_holding_#{@sharesight_account.sharesight_account_id}_#{holding['id']}_#{Date.current}",
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
    # the holding's value per unit in the portfolio's currency. A sold holding
    # has no units to divide by, so it keeps the instrument price (or zero
    # when even that is missing) instead of resolving value per unit.
    def holding_price(holding, quantity)
      price = parse_decimal(holding["instrument_price"])
      currency = @sharesight_account.holding_currencies[holding["id"].to_s]
      return [ currency, price ] if currency && price
      return [ currency || portfolio_currency, price || BigDecimal("0") ] if quantity.zero?

      value = parse_decimal(holding["value"])
      return [ portfolio_currency, value / quantity ] if value

      [ portfolio_currency, price ]
    end

    # Whether it has units on the last snapshot, in any currency, since the
    # open row may have been priced in another one. A row the user remapped to
    # another security still counts through its provider security.
    def still_held?(security)
      return false unless @last_snapshot_date

      held = account.holdings
        .where(date: @last_snapshot_date, account_provider_id: @sharesight_account.account_provider&.id)
        .where.not(qty: 0)
      held.where(security: security).or(held.where(provider_security: security)).exists?
    end
end
