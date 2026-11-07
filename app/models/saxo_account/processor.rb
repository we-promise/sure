class SaxoAccount::Processor
  CALCULATION_RELIABILITY_CODES = %w[
    ApproximatedPrice CurrencyConversionFailed FailedToCalculateCollateral
    NoMarketAccess OkWithConditions PricePending SystemError UnknownPrice
  ].freeze
  ACCEPTED_CALCULATION_RELIABILITY = %w[Ok OkWithConditions].freeze

  def initialize(provider_account)
    @provider_account = provider_account
    @account = provider_account.account
  end

  def normalize_positions(rows)
    grouped = {}
    rows.each do |row|
      base, view, display = row.fetch("PositionBase"), row.fetch("PositionView"), row.fetch("DisplayAndFormat")
      unless base["AccountId"] == @provider_account.account_id && Provider::Saxo::Normalizer::SUPPORTED_ASSETS.include?(base["AssetType"])
        raise Provider::Saxo::Error, "Saxo position account or instrument type is not supported"
      end
      unless ACCEPTED_CALCULATION_RELIABILITY.include?(view["CalculationReliability"])
        reliability = view["CalculationReliability"]
        market_data_unavailable = reliability == "NoMarketAccess" ||
          (reliability == "ApproximatedPrice" && zero_decimal?(view["CurrentPrice"]) && zero_decimal?(view["MarketValueInBaseCurrency"]))
        diagnostic = {
          stage: "positions", reason: "unreliable_valuation",
          calculation_reliability: CALCULATION_RELIABILITY_CODES.include?(reliability) ? reliability : (reliability.nil? ? "missing" : "unknown"),
          price_present: view["CurrentPrice"].present?, value_present: view["MarketValueInBaseCurrency"].present?,
          market_data_may_be_unavailable: market_data_unavailable,
          account_provider_id: @provider_account.account_provider&.id
        }
        message = market_data_unavailable ? "Saxo market data may be unavailable" : "Saxo position valuation is unreliable"
        raise Provider::Saxo::Error.new(message, diagnostic: diagnostic)
      end
      quantity = decimal(base["Amount"])
      price = decimal(view["CurrentPrice"])
      amount = decimal(view["MarketValueInBaseCurrency"])
      raise Provider::Saxo::Error, "Saxo short position or invalid valuation requires review" if quantity.negative? || price.negative? || amount.negative?
      if view["CalculationReliability"] == "OkWithConditions" && quantity.positive? && (price.zero? || amount.zero?)
        raise Provider::Saxo::Error.new("Saxo position valuation is unreliable", diagnostic: {
          stage: "positions", reason: "unreliable_valuation", calculation_reliability: "OkWithConditions",
          account_provider_id: @provider_account.account_provider&.id
        })
      end
      raise Provider::Saxo::Error, "Saxo position identity is invalid" unless base["Uic"].to_s.match?(/\A[1-9]\d*\z/)
      instrument = { "Uic" => base.fetch("Uic"), "AssetType" => base.fetch("AssetType"),
        "Symbol" => display.fetch("Symbol"), "Description" => display["Description"], "Currency" => display.fetch("Currency") }
      key = identity(instrument)
      grouped[key] ||= { instrument: instrument, quantity: BigDecimal("0"), amount: BigDecimal("0"), price: price }
      grouped[key][:quantity] += quantity
      grouped[key][:amount] += amount
    end
    grouped
  rescue KeyError
    raise Provider::Saxo::Error, "Saxo position is incomplete"
  end

  def process(normalized, holdings)
    adapter = Account::ProviderImportAdapter.new(@account)
    normalized[:trades].each do |id, trade|
      external_id = "#{@provider_account.account_id}:trade:#{id}"
      existing = @account.entries.find_by(source: "saxo", external_id: external_id)
      next if existing&.protected_from_sync?
      adapter.import_trade(
        external_id: external_id,
        source: "saxo",
        security: security(trade[:instrument]),
        quantity: trade[:quantity],
        price: trade[:price] * trade[:conversion_rate],
        amount: trade[:amount],
        currency: trade[:currency],
        date: trade[:date],
        activity_label: trade[:activity_label],
        exchange_rate: 1
      )
      imported = @account.entries.find_by!(source: "saxo", external_id: external_id)
      imported.entryable.update!(
        extra: (imported.entryable.extra || {}).merge("saxo" => {
          "instrument_currency" => trade[:instrument]["Currency"],
          "original_price" => trade[:price].to_s,
          "conversion_rate" => trade[:conversion_rate].to_s
        })
      )
    end
    normalized[:bookings].each do |id, booking|
      adapter.import_transaction(
        **booking.except(:activity_label),
        investment_activity_label: booking[:activity_label],
        external_id: "#{@provider_account.account_id}:booking:#{id}",
        source: "saxo",
        allow_heuristic_matching: false,
        replace_extra_namespaces: [ "saxo" ]
      )
    end
    import_holdings(adapter, holdings)
    @account.update!(balance: @provider_account.current_balance, cash_balance: @provider_account.cash_balance)
    @account.ensure_opening_anchor_precedes_entries
    result = @account.set_current_balance(@provider_account.current_balance, schedule_sync: false)
    raise Provider::Saxo::Error, "Saxo current balance could not be reconciled" unless result.success?
  end

  private
    def zero_decimal?(value)
      BigDecimal(value.to_s).zero?
    rescue ArgumentError, TypeError
      false
    end

    def decimal(value)
      Provider::Saxo::Normalizer.decimal(value)
    end

    def identity(instrument)
      "#{instrument.fetch('AssetType')}:#{instrument.fetch('Uic')}"
    end

    def security(instrument)
      # UIC identifies the listing. Never guess a MIC from Saxo's exchange vocabulary.
      Security.find_or_create_by!(ticker: "SAXO-#{identity(instrument)}".upcase, exchange_operating_mic: nil) do |record|
        record.name = [ instrument["Description"], instrument["Symbol"] ].compact.join(" - ")
        record.offline = true
      end
    end

    def import_holdings(adapter, holdings)
      current_ids = []
      holdings.each do |key, holding|
        security_record = security(holding[:instrument])
        current_ids << security_record.id
        quantity, amount = holding.values_at(:quantity, :amount)
        adapter.import_holding(
          security: security_record,
          quantity: quantity,
          amount: amount,
          price: quantity.zero? ? 0 : amount / quantity,
          currency: @provider_account.currency,
          date: Date.current,
          external_id: "saxo:#{@provider_account.account_id}:#{key}:#{Date.current}",
          source: "saxo",
          account_provider_id: @provider_account.account_provider.id
        )
      end
      # A complete empty snapshot closes sold positions while retaining their history.
      previous = @account.holdings.where(account_provider: @provider_account.account_provider)
      previous = previous.where("COALESCE(provider_security_id, security_id) NOT IN (?)", current_ids) if current_ids.any?
      previous.select(:security_id, :provider_security_id, :currency).distinct.each do |old|
        adapter.import_holding(
          security: Security.find(old.provider_security_id || old.security_id),
          quantity: 0,
          amount: 0,
          price: 0,
          currency: old.currency,
          date: Date.current,
          source: "saxo",
          account_provider_id: @provider_account.account_provider.id,
          external_id: "saxo:#{@provider_account.account_id}:closed:#{old.security_id}:#{Date.current}"
        )
      end
    end
end
