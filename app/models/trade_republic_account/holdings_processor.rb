class TradeRepublicAccount::HoldingsProcessor
  include TradeRepublicAccount::DataHelpers

  def initialize(trade_republic_account, exchange_securities: {})
    @trade_republic_account = trade_republic_account
    @exchange_securities = exchange_securities
  end

  def process
    return unless account.present?

    positions = @trade_republic_account.positions
    processed_count = positions.count do |position|
      process_position(position.with_indifferent_access)
    end

    # A validated, complete snapshot is authoritative. Reconcile only after
    # every position was imported successfully; partial provider data must
    # preserve existing holdings.
    if @trade_republic_account.positions_snapshot_complete? && processed_count == positions.size
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

      security = resolve_security(
        isin,
        position[:name],
        symbol: position[:symbol],
        exchange_slug: position[:exchange_slug]
      )
      return unless security

      rematch_bond_holdings!(isin, security) if bond_position?(position)

      quantity = parse_decimal(position[:quantity])
      price    = parse_decimal(position[:price])
      return unless quantity && price && quantity.positive?

      amount = quantity * price
      date   = Date.current

      external_id = "#{position_external_id_prefix}#{isin}_#{date}"

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

    # Positions stored before bonds were marked still carry the shared
    # listing; they are bonds as well.
    def bond_position?(position)
      Provider::TradeRepublicClient.bond?(position) ||
        Provider::TradeRepublicClient.bond_placeholder_listing?(position[:symbol], position[:exchange_slug])
    end

    # Earlier syncs put every bond on Trade Republic's shared "BOND" listing.
    # The external id still names the bond's ISIN, so move this bond's
    # snapshots onto its own security. The shared listing was never the
    # bond's real security, so it doesn't stay as provider_security_id, also
    # not on rows that import_holding already moved.
    def rematch_bond_holdings!(isin, security)
      bond_holdings = account.holdings
        .where("external_id LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like("#{position_external_id_prefix}#{isin}_")}%")
      stale = bond_holdings.where.not(security_id: security.id).where(security_locked: false)

      if stale.exists?
        mismatched_dates = move_holdings_to_security!(stale, security, adopt_provider_security: true)
        log_rematch_collisions(
          "Bond rematch collision kept the bond's own holding market values",
          mismatched_dates,
          isin: isin,
          to_security_id: security.id
        )
      end

      bond_holdings
        .where(security_id: security.id)
        .where.not(provider_security_id: [ nil, security.id ])
        .update_all(provider_security_id: security.id, updated_at: Time.current)
    end

    def position_external_id_prefix
      "trade_republic_position_#{@trade_republic_account.trade_republic_account_id}_"
    end

    def reconcile_stale_holdings!(positions)
      provider_id = @trade_republic_account.account_provider&.id
      return if provider_id.blank?

      prefix = position_external_id_prefix
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
