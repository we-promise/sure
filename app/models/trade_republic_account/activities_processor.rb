class TradeRepublicAccount::ActivitiesProcessor
  include TradeRepublicAccount::DataHelpers

  # Timeline event categories that carry trade payloads once their detail has
  # been resolved by the Trade Republic client boundary.
  CATEGORY_ORDER_EXECUTION = "orderExecution"

  def initialize(trade_republic_account)
    @trade_republic_account = trade_republic_account
  end

  def process
    return { trades: 0, transactions: 0 } unless account.present?

    trade_count = 0
    transaction_count = 0
    split_accounts = linked_cash_account_present?

    Array(@trade_republic_account.raw_timeline_payload).each do |event|
      next unless event.is_a?(Hash)

      next if split_accounts && @trade_republic_account.portfolio? && event.with_indifferent_access[:category].to_s != CATEGORY_ORDER_EXECUTION
      next if @trade_republic_account.cash? && event.with_indifferent_access[:category].to_s == CATEGORY_ORDER_EXECUTION

      case process_event(event.with_indifferent_access)
      when :trade then trade_count += 1
      when :transaction then transaction_count += 1
      end
    end

    reconcile_split_portfolio_transactions!

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

    def import_order_execution(event, detail, external_id, date)
      isin = detail[:isin].to_s
      quantity = parse_decimal(detail[:quantity])

      return false if isin.blank? || quantity.nil? || quantity.zero?

      security = resolve_security(isin, detail[:name] || event[:title])
      return false unless security

      is_buy = quantity.positive?
      signed_quantity = quantity # Bridge reports sells as negative quantities already

      # Amount falls back to |quantity| × price only when the provider omits
      # the exact cash amount. Fees and taxes stay embedded in the provider
      # amount rather than being inferred separately.
      price = parse_decimal(detail[:price])
      price = nil if price&.zero?
      amount = parse_decimal(detail[:amount])
      amount = quantity.abs * price.abs if (!amount || amount.zero?) && price
      return false unless amount && !amount.zero?

      signed_amount = is_buy ? -amount.abs : amount.abs
      price ||= amount.abs / signed_quantity.abs

      entry = import_adapter.import_trade(
        external_id:    external_id,
        security:       security,
        quantity:       signed_quantity,
        price:          price,
        amount:         signed_amount,
        currency:       detail[:currency].presence || currency,
        date:           date,
        name:           build_trade_name(security.ticker, signed_quantity),
        source:         "trade_republic",
        activity_label: is_buy ? t("buy") : t("sell")
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
            provider_detail: detail.except(:amount, :signed_amount, :currency)
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

      event[:category].to_s
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
        metadata: { event_id: event[:id], category: event[:category] }
      )
    end

    def build_trade_name(ticker, signed_quantity)
      action = signed_quantity.negative? ? t("sell") : t("buy")
      "#{action} #{signed_quantity.abs} shares of #{ticker}"
    end
end
