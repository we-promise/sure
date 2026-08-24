class TradeRepublicAccount::HoldingsProcessor
  include TradeRepublicAccount::DataHelpers

  def initialize(trade_republic_account)
    @trade_republic_account = trade_republic_account
  end

  def process
    return unless account.present?

    positions = Array(@trade_republic_account.raw_positions_payload)
    processed_count = positions.count do |position|
      process_position(position.with_indifferent_access)
    end

    # A validated, complete snapshot is authoritative. Reconcile only after
    # every position was imported successfully; partial provider data must
    # preserve existing holdings.
    if @trade_republic_account.holdings_snapshot_complete? && processed_count == positions.size
      reconcile_stale_holdings!(positions)
    end
  end

  private

    def account
      @trade_republic_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def currency
      @trade_republic_account.currency
    end

    def process_position(position)
      isin = position[:isin].to_s
      return if isin.blank?

      security = resolve_security(isin, position[:name])
      return unless security

      quantity = parse_decimal(position[:quantity])
      price    = parse_decimal(position[:price])
      return unless quantity && price && quantity.positive?

      amount = quantity * price
      date   = Date.current

      external_id = "trade_republic_position_#{@trade_republic_account.trade_republic_account_id}_#{isin}_#{date}"

      import_adapter.import_holding(
        security:           security,
        quantity:           quantity,
        amount:             amount,
        currency:           currency,
        date:               date,
        price:              price,
        cost_basis:         parse_decimal(position[:average_cost]),
        external_id:        external_id,
        source:             "trade_republic",
        account_provider_id: @trade_republic_account.account_provider&.id,
        delete_future_holdings: false
      )
      true
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "TradeRepublicAccount::HoldingsProcessor - Failed to process position #{isin}: #{e.message}",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        metadata: { isin: isin, trade_republic_account_id: @trade_republic_account.id }
      )
      false
    end

    def reconcile_stale_holdings!(positions)
      provider_id = @trade_republic_account.account_provider&.id
      return if provider_id.blank?

      prefix = "trade_republic_position_#{@trade_republic_account.trade_republic_account_id}_"
      current_ids = positions.filter_map do |position|
        isin = position.with_indifferent_access[:isin].to_s
        isin.present? ? "#{prefix}#{isin}_#{Date.current}" : nil
      end
      holdings = account.holdings.where(account_provider_id: provider_id)
        .where("external_id LIKE ?", "#{prefix}%#{Date.current}")
      holdings = holdings.where.not(external_id: current_ids) if current_ids.any?
      holdings.destroy_all
    end
end
