class TinkoffInvestAccount::HoldingsProcessor
  include TinkoffInvestAccount::DataHelpers

  def initialize(tinkoff_invest_account)
    @tinkoff_invest_account = tinkoff_invest_account
  end

  def process
    return 0 unless account.present?

    positions = Array(@tinkoff_invest_account.raw_portfolio_payload&.dig("positions"))
    positions.count { |position| process_position(position) }
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
      return false unless quantity&.positive?

      meta = position["resolved_instrument"] || {}
      ticker = (meta["ticker"].presence || position["ticker"].presence || position["figi"].presence || position["instrumentUid"].presence).to_s.strip.upcase
      return false if ticker.blank?

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
      return false unless security

      date = Date.current
      pos_uid = position["instrumentUid"].presence || position["figi"].presence || ticker
      external_id = "tinkoff_invest_pos_#{@tinkoff_invest_account.tinkoff_invest_account_id}_#{pos_uid}_#{date}"

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
end
