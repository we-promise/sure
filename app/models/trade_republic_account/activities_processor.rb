class TradeRepublicAccount::ActivitiesProcessor
  include TradeRepublicAccount::DataHelpers

  SAVEBACK_EVENT_TYPE = "SAVEBACK_AGGREGATE"
  ROUND_UP_EVENT_TYPE = "SPARE_CHANGE_AGGREGATE"

  def initialize(trade_republic_account, exchange_securities: {})
    @trade_republic_account = trade_republic_account
    @exchange_securities = exchange_securities
  end

  def process
    return { trades: 0, transactions: 0 } unless account.present?

    trade_count = 0
    transaction_count = 0

    Array(@trade_republic_account.raw_timeline_payload).each do |event|
      next unless event.is_a?(Hash)

      event = event.with_indifferent_access
      classification = classify_timeline_event(event)

      case classification
      when :ignored
        next
      when :unknown
        record_unknown_event(event)
        next
      end

      next if lifecycle_blocks_import?(event)
      next unless processable_event?(event)

      case process_event(event)
      when :trade then trade_count += 1
      when :transaction then transaction_count += 1
      end
    end

    reconcile_split_portfolio_transactions!
    reconcile_stale_saveback_cash_transactions!
    reconcile_non_importable_entries!

    { trades: trade_count, transactions: transaction_count }
  end

  private

    def i18n_scope
      "trade_republic_items.activities.labels"
    end

    def t(key, **options)
      I18n.t(key, scope: i18n_scope, **options)
    end

    def account
      @trade_republic_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def currency
      @trade_republic_account.currency
    end

    # Saveback and Round Up stay classified as POC_CREATED at the client
    # boundary so other cash withdrawals are unchanged. Routing happens here
    # by eventType: Saveback is portfolio-only; Round Up is portfolio trade
    # plus cash outflow when both accounts are linked.
    def processable_event?(event)
      event_type = event[:eventType].to_s

      return @trade_republic_account.portfolio? if saveback_event?(event_type)
      return true if round_up_event?(event_type)

      category = event[:category].to_s
      return category == CATEGORY_ORDER_EXECUTION if linked_cash_account_present? && @trade_republic_account.portfolio?
      return category != CATEGORY_ORDER_EXECUTION if @trade_republic_account.cash?

      true
    end

    # Events arrive bridge-normalized:
    #   { id:, timestamp:, category:, title:, subtitle:,
    #     detail: { isin, name, quantity (signed), amount (magnitude),
    #               currency, fees, taxes } }
    # detail is present only for events the bridge could normalize; unknown or
    # ambiguous events are skipped with a debug-log entry, never guessed.
    def process_event(event)
      external_id = "trade_republic_event_#{event[:id]}"
      return nil if event[:id].blank?

      date = parse_date(event[:timestamp])
      return nil unless date

      detail = event[:detail] || {}
      event_type = event[:eventType].to_s

      return process_saveback(event, detail, external_id, date) if saveback_event?(event_type)
      return process_round_up(event, detail, external_id, date) if round_up_event?(event_type)

      case event_category(event)
      when CATEGORY_ORDER_EXECUTION
        import_order_execution(event, detail, external_id, date) ? :trade : nil
      when CATEGORY_DEPOSIT
        import_cash_movement(event, detail, external_id, date, label: cash_label(event, default: t("contribution")), sign: -1) ? :transaction : nil
      when CATEGORY_WITHDRAWAL
        import_cash_movement(event, detail, external_id, date, label: cash_label(event, default: t("withdrawal")), sign: 1) ? :transaction : nil
      when CATEGORY_INTEREST
        import_cash_movement(event, detail, external_id, date, label: t("interest"), sign: -1) ? :transaction : nil
      when CATEGORY_DIVIDEND
        import_cash_movement(event, detail, external_id, date, label: t("dividend"), sign: -1) ? :transaction : nil
      else
        record_unknown_event(event)
        nil
      end
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "TradeRepublicAccount::ActivitiesProcessor - Failed to process event #{event[:id]}: #{e.message}",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        metadata: { event_id: event[:id], category: event[:category] }
      )
      nil
    end

    def process_saveback(event, detail, external_id, date)
      return nil unless @trade_republic_account.portfolio?

      import_order_execution(event, detail, external_id, date) ? :trade : nil
    end

    def process_round_up(event, detail, external_id, date)
      if @trade_republic_account.portfolio?
        import_order_execution(event, detail, external_id, date) ? :trade : nil
      else
        import_cash_movement(event, detail, external_id, date, label: t("round_up"), sign: 1) ? :transaction : nil
      end
    end

    def saveback_event?(event_type)
      event_type == SAVEBACK_EVENT_TYPE
    end

    def round_up_event?(event_type)
      event_type == ROUND_UP_EVENT_TYPE
    end

    def import_order_execution(event, detail, external_id, date)
      isin = detail[:isin].to_s
      quantity = parse_decimal(detail[:quantity])

      return false if isin.blank? || quantity.nil? || quantity.zero?

      security = resolve_security(
        isin,
        detail[:name] || event[:title],
        symbol: detail[:symbol],
        exchange_slug: detail[:exchange_slug]
      )
      return false unless security

      is_buy = quantity.positive?
      signed_quantity = quantity # Bridge reports sells as negative quantities already

      fee = parse_decimal(detail[:fees])&.abs
      fee = nil if fee&.zero?
      tax = parse_decimal(detail[:taxes])&.abs
      tax = nil if tax&.zero?
      # Match the client detail parser: cash totals embed fees and taxes.
      costs = (fee || 0) + (tax || 0)

      # Prefer the provider share price. Fall back to cash amount net of costs
      # so the per-share price is not inflated by transaction costs.
      price = parse_decimal(detail[:price])
      price = nil if price&.zero?
      amount = parse_decimal(detail[:amount])
      if (!amount || amount.zero?) && price
        gross = quantity.abs * price.abs
        # Costs increase buy cost and reduce sell proceeds (same as SnapTrade /
        # manual trades).
        amount = is_buy ? gross + costs : gross - costs
      end
      return false unless amount && !amount.zero?

      signed_amount = is_buy ? -amount.abs : amount.abs
      if price.nil?
        # Provider totals include costs: buy total = gross + costs, sell total =
        # gross - costs. Recover share price from the cash amount accordingly.
        gross = is_buy ? amount.abs - costs : amount.abs + costs
        price = gross / signed_quantity.abs if gross.positive?
        price ||= amount.abs / signed_quantity.abs
      end

      entry = import_adapter.import_trade(
        external_id:    external_id,
        security:       security,
        quantity:       signed_quantity,
        price:          price,
        amount:         signed_amount,
        fee:            fee,
        currency:       detail[:currency].presence || currency,
        date:           date,
        name:           build_trade_name(detail[:name], security, signed_quantity),
        source:         "trade_republic",
        activity_label: is_buy ? "Buy" : "Sell"
      )

      trade_metadata = {
        trade_republic: {
          event_id: event[:id],
          event_type: event[:eventType],
          isin: isin,
          fees: detail[:fees],
          taxes: detail[:taxes],
          provider_name: detail[:name]
        }.compact
      }

      if entry&.entryable.is_a?(Trade) && trade_metadata[:trade_republic].present?
        existing = entry.entryable.extra || {}
        merged = existing.deep_merge(trade_metadata.deep_stringify_keys)
        entry.entryable.update!(extra: merged) if merged != existing
      end

      true
    end

    def import_cash_movement(event, detail, external_id, date, label:, sign:)
      amount = parse_decimal(detail[:amount])
      return false unless amount && !amount.zero?

      import_adapter.import_transaction(
        external_id: external_id,
        # The normalized category is the source of truth for direction. TR
        # payloads use different signs across timeline topics, so forwarding
        # `detail[:signed_amount]` would turn deposits into withdrawals (and
        # vice versa) depending on which topic produced the event.
        amount: sign * amount.abs,
        currency: detail[:currency].presence || currency,
        date: date,
        name: event[:title].presence || label,
        notes: event[:subtitle].presence,
        source: "trade_republic",
        category_id: category_for(event, label)&.id,
        kind: transfer_event?(event) ? "funds_movement" : nil,
        investment_activity_label: label,
        extra: {
          trade_republic: {
            event_id: detail[:event_id] || external_id,
            category: detail[:category],
            event_type: event[:eventType],
            title: event[:title],
            subtitle: event[:subtitle],
            provider_detail: detail.except(
              :amount, :signed_amount, :currency, Provider::TradeRepublicClient::PRICE_BACKFILL_ATTEMPTED_AT_KEY
            )
          }.compact
        }
      )

      true
    end

    def category_for(event, label)
      nil
    end

    def transfer_event?(event)
      TRANSFER_EVENT_TYPES.include?(event[:eventType].to_s)
    end

    # Older stored snapshots may still contain CARD_CASH_BACK as
    # PAYMENT_RECEIVED. Trade Republic uses that event type for some card
    # purchases, where the signed provider amount is negative. Normalize this
    # legacy shape before applying the standard cash direction rules.
    def event_category(event)
      signed_amount = parse_decimal(event.dig(:detail, :signed_amount) || event.dig(:detail, :amount))
      return CATEGORY_WITHDRAWAL if event[:eventType].to_s == "CARD_CASH_BACK" && signed_amount&.negative?

      event[:category].to_s.presence ||
        Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES[event[:eventType].to_s].to_s
    end

    def cash_label(event, default:)
      case event[:eventType].to_s
      when "CARD_TRANSACTION", "card_successful_transaction"
        t("card_payment")
      when "CARD_ATM_WITHDRAWAL"
        t("cash_withdrawal")
      when "CARD_ORDER_FEE"
        t("card_fee")
      when "CARD_CASH_BACK"
        t("card_payment")
      when "card_refund", "CARD_REFUND"
        t("card_refund")
      when "TAX_REFUND", "SSP_TAX_CORRECTION", "ssp_tax_correction_invoice"
        t("tax_refund")
      when ROUND_UP_EVENT_TYPE
        t("round_up")
      else
        default
      end
    end

    def reconcile_split_portfolio_transactions!
      return unless @trade_republic_account.portfolio? && linked_cash_account_present?
      cash_account = @trade_republic_account.trade_republic_item.trade_republic_accounts.find_by(kind: "cash")
      return unless cash_account

      cash_event_ids = Array(cash_account.raw_timeline_payload).filter_map do |event|
        event["id"].presence if event.is_a?(Hash)
      end
      return if cash_event_ids.empty?

      stale_entries = account.entries
        .where(source: "trade_republic", entryable_type: "Transaction")
        .where(external_id: cash_event_ids.map { |event_id| "trade_republic_event_#{event_id}" })
      removed_count = stale_entries.count
      stale_entries.destroy_all if removed_count.positive?
      return unless removed_count.positive?

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Removed #{removed_count} legacy cash transaction(s) from split Trade Republic portfolio",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        account: account,
        metadata: { trade_republic_account_id: @trade_republic_account.id, removed_count: removed_count }
      )
    end

    # Saveback used to import as a cash withdrawal. Once split accounts are
    # linked, remove those leftover cash entries only after the portfolio
    # replacement trade exists, and unless the user edited or split them.
    def reconcile_stale_saveback_cash_transactions!
      return unless @trade_republic_account.cash?

      portfolio_account = linked_portfolio_account
      return unless portfolio_account

      saveback_event_ids = Array(@trade_republic_account.raw_timeline_payload).filter_map do |event|
        next unless event.is_a?(Hash)
        next unless event["eventType"].to_s == SAVEBACK_EVENT_TYPE

        event["id"].presence
      end
      return if saveback_event_ids.empty?

      external_ids = saveback_event_ids.map { |event_id| "trade_republic_event_#{event_id}" }
      candidates = account.entries
        .where(source: "trade_republic", entryable_type: "Transaction")
        .where(external_id: external_ids)
        .includes(:entryable)

      removed_count = 0
      skipped_count = 0

      candidates.find_each do |entry|
        event_type = entry.entryable.try(:extra)&.dig("trade_republic", "event_type")
        next if event_type.present? && event_type != SAVEBACK_EVENT_TYPE

        if entry.protected_from_sync? || entry.split_parent? || entry.split_child?
          skipped_count += 1
          DebugLogEntry.capture(
            category: "sync",
            level: "info",
            message: "Skipped removing protected Saveback cash transaction #{entry.external_id}",
            source: "trade_republic",
            family: @trade_republic_account.trade_republic_item.family,
            provider_key: "trade_republic",
            account: account,
            metadata: {
              trade_republic_account_id: @trade_republic_account.id,
              external_id: entry.external_id,
              protection_reason: entry.protection_reason || (entry.split_parent? || entry.split_child? ? :split : nil)
            }
          )
          next
        end

        # Keep the legacy cash row until the portfolio trade is present so an
        # incomplete Saveback detail cannot open a ledger gap.
        unless portfolio_saveback_trade_present?(portfolio_account, entry.external_id)
          skipped_count += 1
          DebugLogEntry.capture(
            category: "sync",
            level: "info",
            message: "Skipped removing Saveback cash transaction #{entry.external_id} until portfolio trade exists",
            source: "trade_republic",
            family: @trade_republic_account.trade_republic_item.family,
            provider_key: "trade_republic",
            account: account,
            metadata: {
              trade_republic_account_id: @trade_republic_account.id,
              external_id: entry.external_id,
              portfolio_account_id: portfolio_account.id
            }
          )
          next
        end

        entry.destroy!
        removed_count += 1
      end

      return unless removed_count.positive? || skipped_count.positive?

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Reconciled stale Saveback cash transactions (removed=#{removed_count}, skipped=#{skipped_count})",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        account: account,
        metadata: {
          trade_republic_account_id: @trade_republic_account.id,
          removed_count: removed_count,
          skipped_count: skipped_count
        }
      )
    end

    def linked_portfolio_account
      portfolio_tr = @trade_republic_account.trade_republic_item.trade_republic_accounts.find_by(kind: "portfolio")
      return unless portfolio_tr

      portfolio_account = portfolio_tr.current_account
      return unless portfolio_account
      return if portfolio_account.pending_deletion? || portfolio_account.disabled?

      portfolio_account
    end

    def portfolio_saveback_trade_present?(portfolio_account, external_id)
      portfolio_account.entries
        .where(source: "trade_republic", entryable_type: "Trade", external_id: external_id)
        .exists?
    end

    # Remove previously imported entries whose upstream events are now deleted
    # or in a terminal non-importable status, unless the user protected them.
    def reconcile_non_importable_entries!
      blocked_ids = Array(@trade_republic_account.raw_timeline_payload).filter_map do |event|
        next unless event.is_a?(Hash)
        next unless lifecycle_blocks_import?(event)

        event["id"].presence || event[:id].presence
      end
      return if blocked_ids.empty?

      external_ids = blocked_ids.map { |event_id| "trade_republic_event_#{event_id}" }
      candidates = account.entries
        .where(source: "trade_republic")
        .where(external_id: external_ids)
        .includes(:entryable)

      removed_count = 0
      skipped_count = 0

      candidates.find_each do |entry|
        if entry.protected_from_sync? || entry.split_parent? || entry.split_child?
          skipped_count += 1
          DebugLogEntry.capture(
            category: "sync",
            level: "info",
            message: "Skipped removing protected Trade Republic entry for non-importable event #{entry.external_id}",
            source: "trade_republic",
            family: @trade_republic_account.trade_republic_item.family,
            provider_key: "trade_republic",
            account: account,
            metadata: {
              trade_republic_account_id: @trade_republic_account.id,
              external_id: entry.external_id,
              protection_reason: entry.protection_reason || (entry.split_parent? || entry.split_child? ? :split : nil)
            }
          )
          next
        end

        entry.destroy!
        removed_count += 1
      end

      return unless removed_count.positive? || skipped_count.positive?

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Reconciled non-importable Trade Republic entries (removed=#{removed_count}, skipped=#{skipped_count})",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        account: account,
        metadata: {
          trade_republic_account_id: @trade_republic_account.id,
          removed_count: removed_count,
          skipped_count: skipped_count
        }
      )
    end

    def linked_cash_account_present?
      @trade_republic_account.trade_republic_item.trade_republic_accounts
        .where(kind: "cash")
        .joins(:account_provider)
        .exists?
    end

    def record_unknown_event(event)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "TradeRepublicAccount::ActivitiesProcessor - Skipping unsupported timeline event (no guessed mapping)",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        metadata: {
          event_id: event[:id],
          event_type: event[:eventType],
          category: event[:category],
          status: event[:status]
        }
      )
    end

    def build_trade_name(provider_name, security, signed_quantity)
      name = provider_name.presence || security.name.presence || security.ticker
      quantity = signed_quantity.abs.to_s("F").sub(/\.0+\z/, "")
      return "#{security.ticker} · #{quantity}x" if name.casecmp?(security.ticker)

      "#{security.ticker} · #{quantity}x #{name}"
    end
end
