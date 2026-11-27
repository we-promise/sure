class Trading212Account::HoldingsProcessor
  include Trading212Account::DataHelpers

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    return unless account.present?

    Array(@trading212_account.raw_positions_payload).each do |position|
      process_position(position.with_indifferent_access)
    end
  end

  private

    def account
      @trading212_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def currency
      @trading212_account.currency
    end

    def process_position(position)
      instrument = (position[:instrument] || {}).with_indifferent_access
      t212_ticker = instrument[:ticker].to_s
      return if t212_ticker.blank?

      isin         = instrument[:isin].presence
      ticker       = standard_ticker(t212_ticker)
      name         = instrument[:name].presence || ticker
      position_ccy = instrument[:currency].presence || currency

      security = resolve_security_direct(isin, ticker, name)
      return unless security

      quantity = parse_decimal(position[:quantity])
      price    = parse_decimal(position[:currentPrice])
      return unless quantity && price && quantity > 0

      position_ccy, price, cost_basis = normalize_minor_units(
        position_ccy, price, parse_decimal(position[:averagePricePaid])
      )

      amount = quantity * price
      date   = Date.current

      external_id = "#{position_external_id_prefix(t212_ticker)}#{date}"

      holding = import_adapter.import_holding(
        security:           security,
        quantity:           quantity,
        amount:             amount,
        currency:           position_ccy,
        date:               date,
        price:              price,
        cost_basis:         cost_basis,
        external_id:        external_id,
        source:             "trading212",
        account_provider_id: @trading212_account.account_provider&.id,
        delete_future_holdings: false
      )

      carry_locked_cost_basis(holding, t212_ticker)
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Trading212Account::HoldingsProcessor - Failed to process position #{t212_ticker}: #{e.message}",
        source: "trading212",
        family: @trading212_account.trading212_item.family,
        provider_key: "trading212",
        metadata: { ticker: t212_ticker, trading212_account_id: @trading212_account.id }
      )
    end

    def position_external_id_prefix(t212_ticker)
      "trading212_position_#{@trading212_account.trading212_account_id}_#{t212_ticker}_"
    end

    def carry_locked_cost_basis(holding, t212_ticker)
      prefix = position_external_id_prefix(t212_ticker)
      return if holding.nil? || holding.cost_basis_locked?
      return unless holding.external_id.to_s.start_with?(prefix)

      previous = account.holdings
        .where(currency: holding.currency)
        .where("holdings.external_id LIKE ?", "#{Holding.sanitize_sql_like(prefix)}%")
        .where("holdings.date < ?", holding.date)
        .order(date: :desc)
        .first
      return unless previous&.cost_basis_locked? && previous.security_id != holding.security_id

      holding.update!(
        cost_basis: previous.cost_basis,
        cost_basis_source: previous.cost_basis_source,
        cost_basis_locked: true
      )
    end
end
