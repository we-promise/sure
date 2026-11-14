class EtoroAccount::HoldingsProcessor
  include EtoroAccount::DataHelpers

  attr_reader :imported_count, :failed_count

  def initialize(etoro_account, securities: nil)
    @etoro_account = etoro_account
    @securities = securities
    @imported_count = 0
    @failed_count = 0
  end

  # Imports one holding per security for the real assets the account shows
  # (EtoroAccount#held_positions), held directly or through copy-trading
  # mirrors. eToro can list one stock on several lines (ABCD and ABCD.RTH);
  # they resolve to one security and make one holding. CFD positions are not
  # holdings: their equity counts as cash, or for an account split into
  # copies as part of its investments holding (see
  # EtoroAccount::CopiesProcessor). Holdings eToro stopped reporting are
  # closed. Returns the value imported.
  def process
    return BigDecimal("0") unless account.present?

    value = positions_by_security.sum(BigDecimal("0")) { |security, positions| process_security(security, positions) }
    close_absent_holdings!
    value
  end

  private

    def account
      @etoro_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def currency
      @etoro_account.currency
    end

    def instruments_map
      @etoro_account.instruments_map
    end

    def provider_id
      @etoro_account.account_provider&.id
    end

    def real_asset_positions
      @etoro_account.held_positions.select do |position|
        field(position, "instrumentID").present? && real_asset?(position)
      end
    end

    # Instruments eToro has not described yet resolve to no security and wait
    # for a later sync.
    def positions_by_security
      @positions_by_security ||= real_asset_positions
        .group_by { |position| security_for_instrument(field(position, "instrumentID")) }
        .except(nil)
    end

    # eToro reports a position's amount and cost in USD and its P&L in the
    # account currency, which agree as the importer takes USD accounts only.
    def process_security(security, positions)
      quantity = positions.sum(BigDecimal("0")) { |position| parse_decimal(field(position, "units")) || 0 }
      return BigDecimal("0") unless quantity.positive?

      cost = positions.sum(BigDecimal("0")) { |position| position_cost(position) || 0 }
      value = positions.sum(BigDecimal("0")) { |position| (parse_decimal(field(position, "amount")) || 0) + position_pnl(position) }

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: value,
        currency: currency,
        date: Date.current,
        price: value / quantity,
        cost_basis: cost.positive? ? cost / quantity : nil,
        external_id: holding_external_id(security),
        source: "etoro",
        account_provider_id: provider_id,
        delete_future_holdings: false
      )

      @imported_count += 1
      value
    rescue => e
      @failed_count += 1
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "EtoroAccount::HoldingsProcessor - Failed to process #{security.ticker}: #{e.message}",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: {
          security_id: security.id,
          instrument_ids: positions.map { |position| field(position, "instrumentID") }.uniq,
          etoro_account_id: @etoro_account.id
        }
      )
      BigDecimal("0")
    end

    # eToro lists only what is open, so a holding it stops reporting was sold.
    # The newest snapshot holding it would otherwise stay current, and the
    # history before the sale would count it twice; a zero for today closes
    # it. A security missing from a snapshot already reads as zero there, so
    # only the newest snapshot's nonzero holdings need one. Holdings are
    # matched by the security eToro's instrument resolved to, which stays in
    # provider_security when a user remaps one. A security an open position
    # resolves to is never zeroed, so a failed import keeps a row an earlier
    # sync wrote today; on the day's first sync it has no row in today's
    # snapshot and reads as zero there until it imports again. Nothing is
    # closed while an open position's instrument is undescribed, as that
    # position may be what keeps a holding open.
    def close_absent_holdings!
      return unless provider_id && @etoro_account.positions_owner&.raw_positions_payload.is_a?(Array)

      holdings = account.holdings.where(account_provider_id: provider_id)
      latest = holdings.maximum(:date)
      return unless latest

      held_ids = positions_by_security.keys.to_set(&:id)
      absent = holdings.where(date: latest).where.not(qty: 0).includes(:security, :provider_security).reject do |holding|
        held_ids.include?((holding.provider_security || holding.security).id)
      end
      return if absent.empty?

      undescribed = real_asset_positions.select { |position| security_for_instrument(field(position, "instrumentID")).nil? }
      return capture_closing_skipped(absent, undescribed) if undescribed.any?

      absent.each do |holding|
        security = holding.provider_security || holding.security

        import_adapter.import_holding(
          security: security,
          quantity: 0,
          amount: 0,
          currency: holding.currency,
          date: Date.current,
          price: holding.price,
          cost_basis: nil,
          external_id: holding_external_id(security),
          source: "etoro",
          account_provider_id: provider_id,
          delete_future_holdings: false
        )
      end
    end

    def capture_closing_skipped(absent, undescribed)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroAccount::HoldingsProcessor - Left #{absent.size} holding(s) eToro no longer reports open: #{undescribed.size} open position(s) are on instruments eToro has not described.",
        source: "etoro",
        provider_key: "etoro",
        **debug_context,
        metadata: {
          security_ids: absent.map(&:security_id).first(100),
          instrument_ids: undescribed.map { |position| field(position, "instrumentID").to_s }.uniq.first(100),
          etoro_account_id: @etoro_account.id
        }
      )
    end

    def holding_external_id(security)
      "etoro_holding_#{@etoro_account.etoro_account_id}_#{security.id}_#{Date.current}"
    end
end
