class TinkoffInvestAccount::HoldingsProcessor
  include TinkoffInvestAccount::DataHelpers

  attr_reader :failed, :skipped_shorts

  def initialize(tinkoff_invest_account)
    @tinkoff_invest_account = tinkoff_invest_account
    @failed = false
    @skipped_shorts = []
    @active_external_ids = []
  end

  def failed?
    @failed
  end

  def process
    return 0 unless account.present?

    payload = @tinkoff_invest_account.raw_portfolio_payload
    positions_present = payload.is_a?(Hash) && payload["positions"].is_a?(Array)
    positions = positions_present ? payload["positions"] : []

    imported = positions.count { |position| process_position(position) }
    capture_skipped_shorts
    reconcile_vanished_holdings! if positions_present && !failed?
    imported
  end

  private

    def account
      @tinkoff_invest_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def portfolio_currency
      @tinkoff_invest_account.currency || "RUB"
    end

    def process_position(position)
      itype = normalize_instrument_type(position["instrumentType"])
      return false if itype == "currency"

      quantity = parse_quotation(position["quantity"])
      return false if quantity.nil? || quantity.zero?

      # Holding validates qty >= 0 and amount >= 0 (no short-position holding
      # model in Sure); record skipped shorts in DebugLogEntry rather than raising.
      if quantity.negative?
        @skipped_shorts << (position["ticker"].presence || position["figi"].presence || position["instrumentUid"])
        return false
      end

      meta = position["resolved_instrument"] || {}
      ticker = (meta["ticker"].presence || position["ticker"].presence || position["figi"].presence || position["instrumentUid"].presence).to_s.strip.upcase
      if ticker.blank?
        @failed = true
        return false
      end

      clean_price, price_ccy = parse_money(position["currentPrice"], meta["currency"] || portfolio_currency)
      nkd, = parse_money(position["currentNkd"], price_ccy)
      avg_cost, = parse_money(position["averagePositionPrice"], price_ccy)

      unit_price = clean_price || BigDecimal("0")
      unit_price += nkd if itype == "bond" && nkd&.positive?
      unit_price = BigDecimal("0") if unit_price.negative?

      security = resolve_security(
        ticker: ticker,
        exchange_operating_mic: meta["exchange_operating_mic"],
        country_code: meta["country_code"],
        name: meta["name"].presence || ticker,
        logo_url: meta["logo_url"]
      )
      unless security
        @failed = true
        return false
      end

      date = Date.current
      pos_uid = position["instrumentUid"].presence || position["figi"].presence || ticker
      external_id = "tinkoff_invest_pos_#{@tinkoff_invest_account.tinkoff_invest_account_id}_#{pos_uid}_#{date}"
      @active_external_ids << external_id

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: (quantity * unit_price).round(4),
        currency: price_ccy,
        date: date,
        price: unit_price,
        cost_basis: avg_cost && !avg_cost.negative? ? avg_cost : nil,
        external_id: external_id,
        source: "tinkoff_invest",
        account_provider_id: @tinkoff_invest_account.account_provider&.id,
        delete_future_holdings: false
      )

      true
    rescue => e
      @failed = true
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "TinkoffInvestAccount::HoldingsProcessor - Failed to process position #{position['figi'] || position['instrumentUid']}: #{e.message}",
        source: "tinkoff_invest",
        family: @tinkoff_invest_account.tinkoff_invest_item.family,
        provider_key: "tinkoff_invest",
        metadata: {
          figi: position["figi"],
          instrument_uid: position["instrumentUid"],
          tinkoff_invest_account_id: @tinkoff_invest_account.id
        }
      )
      false
    end

    def capture_skipped_shorts
      return if @skipped_shorts.empty?

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Skipped short T-Invest position(s); Sure Holding requires non-negative qty",
        source: "tinkoff_invest",
        family: @tinkoff_invest_account.tinkoff_invest_item.family,
        provider_key: "tinkoff_invest",
        account_provider: @tinkoff_invest_account.account_provider,
        metadata: {
          tinkoff_invest_account_id: @tinkoff_invest_account.id,
          skipped_short_instruments: @skipped_shorts.uniq
        }
      )
    end

    # Zero-quantity holdings for today advance Account#current_holdings' max
    # snapshot date without erasing historical holdings from earlier dates.
    def reconcile_vanished_holdings!
      provider_id = @tinkoff_invest_account.account_provider&.id
      return if provider_id.blank?

      scope = account.holdings.where(account_provider_id: provider_id)
      latest_date = scope.maximum(:date)
      return if latest_date.blank?

      today = Date.current
      scope.where(date: latest_date).where.not(qty: 0).find_each do |holding|
        next if latest_date == today && holding.external_id.present? && @active_external_ids.include?(holding.external_id)

        security = holding.provider_security || holding.security
        next if account.holdings.where(security: [ security, holding.security ], date: today, currency: holding.currency)
          .where.not(account_provider_id: [ nil, provider_id ]).exists?

        zero_ext_id = zero_external_id_for(holding, today)
        next if @active_external_ids.include?(zero_ext_id)

        import_adapter.import_holding(
          security: security,
          quantity: 0,
          amount: 0,
          currency: holding.currency,
          date: today,
          price: holding.price,
          external_id: zero_ext_id,
          source: "tinkoff_invest",
          account_provider_id: provider_id,
          delete_future_holdings: false
        )
      end
    end

    def zero_external_id_for(holding, date)
      if holding.external_id.present?
        holding.external_id.sub(/_\d{4}-\d{2}-\d{2}\z/, "_#{date}")
      else
        "tinkoff_invest_pos_#{@tinkoff_invest_account.tinkoff_invest_account_id}_#{holding.security_id}_#{date}"
      end
    end
end
