class TradeRepublicAccount::ActivitiesProcessor
  include TradeRepublicAccount::DataHelpers

  SAVEBACK_EVENT_TYPE = "SAVEBACK_AGGREGATE"
  ROUND_UP_EVENT_TYPE = "SPARE_CHANGE_AGGREGATE"
  SAVINGS_PLAN_INVOICE_EVENT_TYPE = "SAVINGS_PLAN_INVOICE_CREATED"
  SAVINGS_PLAN_EXECUTION_EVENT_TYPES = %w[TRADING_SAVINGSPLAN_EXECUTED SAVINGS_PLAN_EXECUTED].freeze
  ACTIVITY_LABELS_BY_KEY = {
    "contribution" => "Contribution",
    "withdrawal" => "Withdrawal",
    "interest" => "Interest",
    "dividend" => "Dividend",
    "card_fee" => "Fee",
    "round_up" => "Buy"
  }.freeze
  CASH_UNLABELED_KEYS = %w[contribution withdrawal].freeze
  SETTLEMENT_COUNTERPART_PREFIX = "trade_republic_settlement_"

  def initialize(trade_republic_account, exchange_securities: {})
    @trade_republic_account = trade_republic_account
    @exchange_securities = exchange_securities
  end

  def process
    return { trades: 0, transactions: 0 } unless account.present?

    trade_count = 0
    transaction_count = 0

    # Also before the events: a trade that moved to the Crypto account has to
    # lose its portfolio counterpart before its settlement can link to a new
    # one on the Crypto account.
    reconcile_settlement_counterparts!

    timeline_events.each do |event|
      next unless event.is_a?(Hash)

      event = event.with_indifferent_access
      classification = classify_timeline_event(event)
      next if classification == :ignored
      next if lifecycle_blocks_import?(event)
      # After routing, so split portfolio/cash connections log an unknown
      # event once (from the cash side) instead of twice.
      next unless processable_event?(event)

      if classification == :unknown
        record_unknown_event(event)
        next
      end

      case process_event(event)
      when :trade then trade_count += 1
      when :transaction then transaction_count += 1
      end
    end

    reconcile_split_portfolio_transactions!
    reconcile_moved_crypto_trades!
    reconcile_stale_saveback_cash_transactions!
    reconcile_non_importable_entries!
    reconcile_settlement_counterparts!

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

    # Trade Republic settles trades directly against the cash balance. The
    # importer keeps order executions on the portfolio payload only, so the
    # cash account reads them from there to book the settlement. Portfolio
    # copies come first so they win the dedupe: a cash snapshot retained from
    # a failed timeline update can still hold an order execution whose
    # portfolio copy has since been deleted.
    # The Crypto account stores no timeline of its own: it takes the crypto
    # events from the portfolio's.
    def timeline_events
      @timeline_events ||= begin
        events = if @trade_republic_account.crypto?
          portfolio_timeline_events.select { |event| event.is_a?(Hash) && crypto_event?(event.with_indifferent_access) }
        else
          Array(@trade_republic_account.raw_timeline_payload)
        end
        events = portfolio_order_execution_events + events if @trade_republic_account.cash?
        events.uniq { |event| event.is_a?(Hash) ? (event["id"] || event[:id]).presence || event : event }
      end
    end

    def portfolio_order_execution_events
      portfolio_timeline_events.select do |event|
        event.is_a?(Hash) && event_category(event.with_indifferent_access) == CATEGORY_ORDER_EXECUTION
      end
    end

    def portfolio_timeline_events
      Array(@trade_republic_account.sibling("portfolio")&.raw_timeline_payload)
    end

    # Matches the positions the Crypto account holds: an XF000 pseudo-ISIN,
    # or the ISIN of a position Trade Republic lists under crypto. A trade the
    # Crypto account already holds stays there after the position is closed
    # and leaves the snapshot.
    def crypto_event?(event)
      detail = event[:detail]
      return false unless detail.is_a?(Hash)

      isin = detail.with_indifferent_access[:isin].to_s
      TradeRepublicAccount.crypto_isin?(isin) ||
        crypto_position_isins.include?(isin) ||
        crypto_account_trade_ids.include?("trade_republic_event_#{event[:id]}")
    end

    def crypto_account_trade_ids
      @crypto_account_trade_ids ||= begin
        crypto_account = @trade_republic_account.sibling("crypto")&.usable_account
        ids = crypto_account&.entries&.where(source: "trade_republic", entryable_type: "Trade")&.pluck(:external_id)
        Array(ids).to_set
      end
    end

    def crypto_position_isins
      @crypto_position_isins ||= Array(@trade_republic_account.sibling("portfolio")&.raw_positions_payload)
        .select { |position| TradeRepublicAccount.crypto_position?(position) }
        .filter_map { |position| position.with_indifferent_access[:isin].to_s.presence }
        .to_set
    end

    # Saveback and Round Up stay classified as POC_CREATED at the client
    # boundary so other cash withdrawals are unchanged. Routing happens here
    # by eventType: Saveback is a trade only; Round Up is a trade plus cash
    # outflow when both accounts are linked. Crypto trades go to the Crypto
    # account once it is linked, except a portfolio copy the user edited.
    def processable_event?(event)
      event_type = event[:eventType].to_s

      if crypto_event?(event)
        return false if @trade_republic_account.portfolio? && crypto_split?
        return false if @trade_republic_account.crypto? && protected_portfolio_trade?(event)
      end

      return @trade_republic_account.holds_securities? if saveback_event?(event_type)
      return true if round_up_event?(event_type)

      category = event[:category].to_s
      return category == CATEGORY_ORDER_EXECUTION if @trade_republic_account.crypto?
      return category == CATEGORY_ORDER_EXECUTION if linked_cash_account_present? && @trade_republic_account.portfolio?

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
        return nil if duplicate_savings_plan_invoice?(event, detail, date)
        return import_order_settlement(event, detail, external_id, date) ? :transaction : nil if @trade_republic_account.cash?

        import_order_execution(event, detail, external_id, date) ? :trade : nil
      when CATEGORY_DEPOSIT
        import_labeled_cash_movement(event, detail, external_id, date, cash_label_key(event, default: "contribution"), sign: -1)
      when CATEGORY_WITHDRAWAL
        import_labeled_cash_movement(event, detail, external_id, date, cash_label_key(event, default: "withdrawal"), sign: 1)
      when CATEGORY_INTEREST
        import_labeled_cash_movement(event, detail, external_id, date, "interest", sign: -1)
      when CATEGORY_DIVIDEND
        import_labeled_cash_movement(event, detail, external_id, date, "dividend", sign: -1)
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
      return nil unless @trade_republic_account.holds_securities?

      import_order_execution(event, detail, external_id, date) ? :trade : nil
    end

    def process_round_up(event, detail, external_id, date)
      if @trade_republic_account.holds_securities?
        import_order_execution(event, detail, external_id, date) ? :trade : nil
      else
        import_labeled_cash_movement(event, detail, external_id, date, "round_up", sign: 1, kind: "investment_contribution", settles_trade: true)
      end
    end

    # Trade Republic switched savings-plan executions from invoices to
    # TRADING_SAVINGSPLAN_EXECUTED. Should an execution ever arrive in both
    # shapes, import only the execution.
    def duplicate_savings_plan_invoice?(event, detail, date)
      return false unless event[:eventType].to_s == SAVINGS_PLAN_INVOICE_EVENT_TYPE

      key = savings_plan_key(detail, date)
      return false unless savings_plan_execution_keys.include?(key)

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Skipped Trade Republic savings-plan invoice duplicated by an execution event",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        account: account,
        metadata: { event_id: event[:id], isin: key[0], date: key[1], quantity: key[2]&.to_s("F") }
      )
      true
    end

    def savings_plan_execution_keys
      @savings_plan_execution_keys ||= timeline_events.each_with_object(Set.new) do |event, keys|
        next unless event.is_a?(Hash)

        event = event.with_indifferent_access
        next unless SAVINGS_PLAN_EXECUTION_EVENT_TYPES.include?(event[:eventType].to_s)
        next unless importable_timeline_event?(event)

        keys << savings_plan_key(event[:detail] || {}, parse_date(event[:timestamp]))
      end
    end

    def savings_plan_key(detail, date)
      [ detail[:isin].to_s, date, parse_decimal(detail[:quantity])&.abs ]
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

      # Sure trade amounts are cash impact: buys spend cash, sells return it.
      signed_amount = is_buy ? amount.abs : -amount.abs
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

    # The timeline list amount is what Trade Republic booked against the cash
    # balance, fees and taxes included. Unlike cash movements (see
    # import_cash_movement), order executions carry a consistent sign across
    # topics: negative for buys, positive for sales. Payloads that only carry
    # a magnitude fall back to the traded quantity; without either signal the
    # direction is unknown and nothing is booked.
    # Buys count as investment contributions in budgets; sale proceeds are a
    # funds movement rather than income. Neither gets a category.
    def import_order_settlement(event, detail, external_id, date)
      signed_amount = parse_decimal(detail[:signed_amount])
      amount = signed_amount || parse_decimal(detail[:amount])
      return false unless amount && !amount.zero?

      quantity = parse_decimal(detail[:quantity])
      return false if signed_amount.nil? && (quantity.nil? || quantity.zero?)

      outflow = signed_amount ? signed_amount.negative? : quantity.positive?

      import_cash_movement(
        event,
        detail.merge(amount: amount.abs),
        external_id,
        date,
        label: outflow ? "Buy" : "Sell",
        activity_label: outflow ? "Buy" : "Sell",
        sign: outflow ? 1 : -1,
        kind: outflow ? "investment_contribution" : "funds_movement",
        settles_trade: true
      )
    end

    # The label key names the entry (in the sync's locale) when Trade Republic
    # sends no title, and picks the stored activity label.
    def import_labeled_cash_movement(event, detail, external_id, date, label_key, sign:, kind: nil, settles_trade: false)
      import_cash_movement(
        event, detail, external_id, date,
        label: t(label_key), activity_label: activity_label_for(label_key), sign: sign, kind: kind,
        settles_trade: settles_trade
      ) ? :transaction : nil
    end

    def import_cash_movement(event, detail, external_id, date, label:, activity_label:, sign:, kind: nil, settles_trade: false)
      amount = parse_decimal(detail[:amount])
      return false unless amount && !amount.zero?

      legacy_kind = legacy_cash_kinds[external_id]
      entry = import_adapter.import_transaction(
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
        kind: kind || (transfer_event?(event) && !@trade_republic_account.cash? ? "funds_movement" : nil),
        investment_activity_label: activity_label,
        extra: {
          trade_republic: {
            event_id: detail[:event_id] || external_id,
            category: detail[:category],
            event_type: event[:eventType],
            title: event[:title],
            subtitle: event[:subtitle],
            provider_detail: detail.except(
              :amount, :signed_amount, :currency, *Provider::TradeRepublicClient::RETRY_MARKER_KEYS
            )
          }.compact
        }
      )
      reset_legacy_cash_kind!(entry, event, legacy_kind) if legacy_kind && kind.nil?
      link_settlement_counterpart!(entry) if settles_trade

      true
    end

    # The portfolio account holds no cash: Trade Republic settles every trade
    # on the cash account. Each trade still moves the portfolio's cash in
    # Sure, so book the opposite leg there and link both legs as a transfer.
    # The portfolio's cash then nets to zero per trade, and the settlement
    # shows which account the money went to. Without the portfolio trade the
    # counterpart would itself leave cash on the portfolio, so it waits for
    # the trade.
    def link_settlement_counterpart!(cash_entry)
      cash_transaction = cash_entry&.entryable
      return unless cash_transaction.is_a?(Transaction)

      securities_account = securities_account_with_trade(cash_entry.external_id)
      return unless securities_account

      counterpart = securities_import_adapter(securities_account).import_transaction(
        external_id: settlement_counterpart_external_id(cash_entry.external_id),
        amount: -cash_entry.amount,
        currency: cash_entry.currency,
        date: cash_entry.date,
        name: cash_entry.amount.positive? ? "Transfer from #{account.name}" : "Transfer to #{account.name}",
        source: "trade_republic",
        kind: "funds_movement",
        investment_activity_label: "Transfer",
        allow_heuristic_matching: false,
        extra: { trade_republic: { settlement_for: cash_entry.external_id } }
      )
      counterpart_transaction = counterpart&.entryable
      return unless counterpart_transaction.is_a?(Transaction)

      inflow, outflow = cash_entry.amount.positive? ? [ counterpart_transaction, cash_transaction ] : [ cash_transaction, counterpart_transaction ]
      return if inflow.transfer.present? || outflow.transfer.present?
      # A user who unlinked the pair keeps it unlinked.
      return if RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)

      Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")
    end

    def securities_import_adapter(securities_account)
      @securities_import_adapters ||= {}
      @securities_import_adapters[securities_account.id] ||= Account::ProviderImportAdapter.new(securities_account)
    end

    def settlement_counterpart_external_id(settlement_external_id)
      settlement_external_id.sub(/\Atrade_republic_event_/, SETTLEMENT_COUNTERPART_PREFIX)
    end

    # Stored as fixed Transaction::ACTIVITY_LABELS values: budgets, the import
    # adapter and the label picker compare against them, so they must not
    # follow the locale a sync runs in. Card activity carries no label. On the
    # cash account deposits and withdrawals move money on a checking balance,
    # so they carry none either; a Contribution label would make the adapter
    # book them as investment_contribution.
    def activity_label_for(label_key)
      return nil if @trade_republic_account.cash? && CASH_UNLABELED_KEYS.include?(label_key)

      ACTIVITY_LABELS_BY_KEY[label_key]
    end

    # Cash-account deposits and withdrawals are imported as standard
    # transactions; automatic transfer matching turns them into a transfer
    # when the counterpart account is in Sure, whatever the payment type.
    # Earlier syncs stored deposits as investment contributions (with the
    # category and label the adapter assigned with that kind) and payment
    # events as funds movements. Reset those rows unless the user edited them
    # or they belong to a matched transfer. Only rows stored with such a kind
    # are passed in: a family can assign the same category or label through a
    # Rule, which must survive a sync.
    def reset_legacy_cash_kind!(entry, event, legacy_kind)
      transaction = entry&.entryable
      return unless transaction.is_a?(Transaction)
      return if entry.protected_from_sync? || transaction.transfer.present?

      if legacy_kind == "investment_contribution"
        return unless entry.amount.negative?

        attrs = { kind: "standard" }
        attrs[:category_id] = nil if investment_contribution_category_ids.include?(transaction.category_id) &&
          !rule_assigned?(transaction, :category_id)
        attrs[:investment_activity_label] = nil if transaction.investment_activity_label == "Contribution" &&
          !rule_assigned?(transaction, :investment_activity_label)
        transaction.update!(attrs)
      elsif transfer_event?(event)
        transaction.update!(kind: "standard")
      end
    end

    # A Rule can assign the same category or label to a legacy row before this
    # reset runs; the value then belongs to the Rule.
    def rule_assigned?(transaction, attribute)
      transaction.data_enrichments.exists?(attribute_name: attribute.to_s, source: "rule")
    end

    # Read before the first cash movement is imported, while it still holds
    # the kind earlier syncs stored.
    def legacy_cash_kinds
      @legacy_cash_kinds ||=
        if @trade_republic_account.cash?
          Transaction.where(kind: %w[investment_contribution funds_movement])
            .joins(:entry)
            .where(entries: { account_id: account.id, source: "trade_republic" })
            .pluck("entries.external_id", :kind)
            .to_h
        else
          {}
        end
    end

    def investment_contribution_category_ids
      @investment_contribution_category_ids ||= account.family.categories
        .where(name: Category.all_investment_contributions_names)
        .pluck(:id)
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

    def cash_label_key(event, default:)
      case event[:eventType].to_s
      when "CARD_TRANSACTION", "card_successful_transaction", "CARD_CASH_BACK"
        "card_payment"
      when "CARD_ATM_WITHDRAWAL"
        "cash_withdrawal"
      when "CARD_ORDER_FEE"
        "card_fee"
      when "card_refund", "CARD_REFUND"
        "card_refund"
      when "TAX_REFUND", "SSP_TAX_CORRECTION", "ssp_tax_correction_invoice"
        "tax_refund"
      when ROUND_UP_EVENT_TYPE
        "round_up"
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
      return if linked_securities_accounts.empty?

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
        unless securities_account_with_trade(entry.external_id)
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
              external_id: entry.external_id
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

    # The Portfolio and Crypto accounts whose trades the Cash account settles.
    def linked_securities_accounts
      @linked_securities_accounts ||= %w[portfolio crypto].filter_map do |kind|
        @trade_republic_account.sibling(kind)&.usable_account
      end
    end

    def securities_account_with_trade(external_id)
      linked_securities_accounts.find do |securities_account|
        securities_account.entries
          .where(source: "trade_republic", entryable_type: "Trade", external_id: external_id)
          .exists?
      end
    end

    # Runs last, after this run removed stale cash entries and the portfolio
    # run removed stale trades: a counterpart without both would put cash on
    # the portfolio again.
    def reconcile_settlement_counterparts!
      return unless @trade_republic_account.cash?

      settlement_ids = account.entries
        .where(source: "trade_republic", entryable_type: "Transaction")
        .pluck(:external_id)
      linked_securities_accounts.each do |securities_account|
        reconcile_settlement_counterparts_on!(securities_account, settlement_ids)
      end
    end

    def reconcile_settlement_counterparts_on!(securities_account, settlement_ids)
      trade_ids = securities_account.entries
        .where(source: "trade_republic", entryable_type: "Trade")
        .pluck(:external_id)
      linked_ids = (settlement_ids & trade_ids).map { |id| settlement_counterpart_external_id(id) }

      stale_entries = securities_account.entries
        .where(source: "trade_republic", entryable_type: "Transaction")
        .where("external_id LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(SETTLEMENT_COUNTERPART_PREFIX)}%")
        .where.not(external_id: linked_ids)

      removed_count = 0
      stale_entries.find_each do |entry|
        next if entry.protected_from_sync?

        entry.destroy!
        removed_count += 1
      end
      return unless removed_count.positive?

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Removed #{removed_count} Trade Republic settlement counterpart(s) without a settlement or trade",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        account: securities_account,
        metadata: { trade_republic_account_id: @trade_republic_account.id, removed_count: removed_count }
      )
    end

    # Once the Crypto account is linked, it imports the crypto trades the
    # portfolio held until then. Remove the portfolio copies after the Crypto
    # account has its own. A trade whose portfolio copy or settlement
    # counterpart the user edited stays on the portfolio, and the Crypto
    # account skips it (see processable_event?).
    def reconcile_moved_crypto_trades!
      return unless @trade_republic_account.crypto?

      portfolio_account = @trade_republic_account.sibling("portfolio")&.usable_account
      return unless portfolio_account

      moved_ids = account.entries.where(source: "trade_republic", entryable_type: "Trade").pluck(:external_id)
      return if moved_ids.empty?

      removed_count = 0
      portfolio_account.entries
        .where(source: "trade_republic", entryable_type: "Trade", external_id: moved_ids)
        .find_each do |entry|
          next if entry.protected_from_sync?

          entry.destroy!
          removed_count += 1
        end
      return unless removed_count.positive?

      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "Moved #{removed_count} Trade Republic crypto trade(s) from the portfolio to the Crypto account",
        source: "trade_republic",
        family: @trade_republic_account.trade_republic_item.family,
        provider_key: "trade_republic",
        account: portfolio_account,
        metadata: { trade_republic_account_id: @trade_republic_account.id, removed_count: removed_count }
      )
    end

    def protected_portfolio_trade?(event)
      portfolio_account = @trade_republic_account.sibling("portfolio")&.current_account
      return false unless portfolio_account

      external_id = "trade_republic_event_#{event[:id]}"
      portfolio_account.entries
        .where(source: "trade_republic", external_id: [ external_id, settlement_counterpart_external_id(external_id) ])
        .any?(&:protected_from_sync?)
    end

    # Remove previously imported entries whose upstream events are now deleted,
    # hidden or in a terminal non-importable status, unless the user protected
    # them. Events blocked only by the free-text subtitle heuristic are skipped
    # on import but never delete existing entries.
    def reconcile_non_importable_entries!
      explicit_ids = []
      heuristic_ids = []
      timeline_events.each do |event|
        next unless event.is_a?(Hash)
        next unless lifecycle_blocks_import?(event)

        event_id = event["id"].presence || event[:id].presence
        next if event_id.blank?

        (explicit_lifecycle_block?(event) ? explicit_ids : heuristic_ids) << "trade_republic_event_#{event_id}"
      end
      return if explicit_ids.empty? && heuristic_ids.empty?

      candidates = account.entries
        .where(source: "trade_republic")
        .where(external_id: explicit_ids + heuristic_ids)
        .includes(:entryable)

      removed_count = 0
      skipped_count = 0
      heuristic_ids = heuristic_ids.to_set

      candidates.find_each do |entry|
        if heuristic_ids.include?(entry.external_id)
          skipped_count += 1
          DebugLogEntry.capture(
            category: "sync",
            level: "info",
            message: "Kept Trade Republic entry #{entry.external_id} flagged only by its subtitle",
            source: "trade_republic",
            family: @trade_republic_account.trade_republic_item.family,
            provider_key: "trade_republic",
            account: account,
            metadata: { trade_republic_account_id: @trade_republic_account.id, external_id: entry.external_id }
          )
          next
        end

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

    def crypto_split?
      return @crypto_split if defined?(@crypto_split)

      @crypto_split = @trade_republic_account.crypto_split?
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
