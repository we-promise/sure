class TradeRepublicItem::Importer
  MAX_TIMELINE_EVENTS = 5_000
  # Fetches the latest Trade Republic state through the provider client and
  # stores normalized raw payloads on the item's accounts.
  #
  # Failure semantics: any provider error propagates without touching stored
  # payloads, so a failed sync can never erase known financial state. The only
  # destructive reconciliation (stale holdings cleanup) happens later in
  # TradeRepublicAccount::Processor after a fully validated response.

  attr_reader :trade_republic_item, :provider

  def initialize(trade_republic_item, provider:)
    @trade_republic_item = trade_republic_item
    @provider = provider
  end

  def import
    pea_known = trade_republic_item.trade_republic_accounts.any?(&:pea?)
    full_fetch = force_full_timeline_fetch?
    stored_events = trade_republic_item.trade_republic_accounts.any? { |account| Array(account.raw_timeline_payload).any? }
    result = fetch_from_provider(full_timeline: full_fetch, session_txt: trade_republic_item.session_blob)

    # The first time a PEA shows up, its past trades are still stored on the
    # primary account without the cash account number that routes them.
    # Fetch the whole timeline once so they can move to the PEA.
    if !full_fetch && !pea_known && stored_events && result.data["status"] != "session_expired" &&
        Array(result.data["tax_wrapper_accounts"]).any?
      result = fetch_from_provider(
        full_timeline: true,
        session_txt: result.data["session_txt"].presence || trade_republic_item.session_blob
      )
    end

    data = result.data
    domain_statuses = normalized_domain_statuses(data)

    if data["status"] == "session_expired"
      trade_republic_item.update!(status: :requires_update)
      raise Provider::TradeRepublicClient::AuthenticationRequired,
        "Trade Republic session expired. Re-authentication required."
    end

    capped_topics = []
    ActiveRecord::Base.transaction do
      capped_topics = upsert_account(data, domain_statuses: domain_statuses)
      trade_republic_item.update!(
        status: :good,
        newest_event_id: timeline_cursor_for(data, domain_statuses),
        timeline_cursors: timeline_cursors_for(data, domain_statuses, capped_topics: capped_topics),
        session_blob: data["session_txt"].presence || trade_republic_item.session_blob
      )
    end

    record_provider_warnings(Array(data["warnings"]) + importer_warnings(capped_topics: capped_topics))

    {
      success: true,
      detail_backfill_count: data["detail_backfill_count"].to_i,
      timeline_backfill_count: Provider::TradeRepublicClient.pending_timeline_backfills(trade_republic_item.timeline_cursors)
    }
  end

  private

    def fetch_from_provider(full_timeline:, session_txt:)
      provider.sync(
        session_txt: session_txt,
        known_newest_event_id: full_timeline ? nil : trade_republic_item.newest_event_id.presence,
        timeline_cursors: full_timeline ? {} : trade_republic_item.timeline_cursors,
        enrich_events: events_needing_detail_enrichment,
        symbol_lookup_isins: isins_needing_symbol_lookup,
        known_instrument_symbols: stored_instrument_symbols
      )
    end

    # Returns the topics whose fetched events the size cap of the stored
    # timeline dropped.
    def upsert_account(data, domain_statuses:)
      account_info = data["account"] || {}
      unless domain_statuses["account_metadata"] == "success"
        raise Provider::TradeRepublicClient::MalformedResponse,
          "Trade Republic account metadata was not fetched successfully"
      end

      account_id = account_info["brokerage_account_id"].presence
      if account_id.blank?
        raise Provider::TradeRepublicClient::MalformedResponse,
          "Trade Republic response did not contain a brokerage account ID"
      end
      currency = account_info["currency"].presence ||
                 trade_republic_item.currency.presence ||
                 trade_republic_item.family.currency
      portfolio_account = trade_republic_item.trade_republic_accounts.find_by(kind: "portfolio")
      wrappers = Array(data["tax_wrapper_accounts"]).select { |wrapper| wrapper.is_a?(Hash) }
      pea_cash_ids = tax_wrapper_cash_account_ids(wrappers)
      primary_event = ->(event) { !tax_wrapper_event?(event, pea_cash_ids) || pea_transfer_event?(event) }

      portfolio_capped = upsert_kind(
        kind: "portfolio",
        external_id: account_id,
        name: build_account_name(account_id, kind: "portfolio"),
        currency: currency,
        current_balance: portfolio_balance(data, fallback: portfolio_account&.current_balance),
        cash_balance: 0,
        positions: Array(data["positions"]),
        events: data["events"],
        topic_event_ids: data["timeline_topic_event_ids"],
        instrument_symbols: data["instrument_symbols"],
        unresolved_symbol_isins: data["unresolved_symbol_isins"],
        warnings: position_warnings(data),
        domain_statuses: domain_statuses,
        keep_event: primary_event
      )
      # Pass every event into the cash merge, including orderExecution. Filtering
      # happens after merge so a newly categorized savings-plan event can replace
      # and remove its older unmapped cash copy.
      cash_capped = upsert_kind(
        kind: "cash",
        external_id: "cash:#{account_id}",
        name: build_account_name(account_id, kind: "cash"),
        currency: currency,
        current_balance: cash_balance(data),
        cash_balance: cash_balance(data),
        positions: [],
        events: Array(data["events"]),
        topic_event_ids: data["timeline_topic_event_ids"],
        instrument_symbols: data["instrument_symbols"],
        warnings: [],
        domain_statuses: domain_statuses,
        keep_event: primary_event
      )
      upsert_crypto_account(account_id, currency, domain_statuses)
      pea_capped = pea_wrappers(wrappers).flat_map do |wrapper|
        upsert_pea_account(wrapper, data, currency: currency, domain_statuses: domain_statuses)
      end
      portfolio_capped | cash_capped | pea_capped
    end

    # The PEA is a single Investment account: its positions, its own cash and
    # the timeline events booked on its cash account (plus the transfers that
    # fund it, which also show on the primary cash account).
    def upsert_pea_account(wrapper, data, currency:, domain_statuses:)
      sec_acc_no = wrapper["securities_account_id"].to_s
      return [] if sec_acc_no.blank?

      pea = trade_republic_item.trade_republic_accounts.find_by(kind: "pea")
      pea_cash_ids = tax_wrapper_cash_account_ids([ wrapper ])
      wrapper_statuses = wrapper["domain_statuses"].is_a?(Hash) ? wrapper["domain_statuses"] : {}
      positions = Array(wrapper["positions"])
      portfolio_ok = wrapper_statuses["portfolio"] == "success"
      cash_ok = wrapper_statuses["cash"] == "success"
      cash = cash_ok ? (parse_decimal(wrapper.dig("cash", "amount")) || BigDecimal("0")) : pea&.cash_balance

      positions_total = if portfolio_ok
        positions_value(positions, fallback: pea && pea.current_balance.to_d - pea.cash_balance.to_d)
      elsif pea
        pea.current_balance.to_d - pea.cash_balance.to_d
      end

      upsert_kind(
        kind: "pea",
        external_id: "pea:#{sec_acc_no}",
        name: build_account_name(sec_acc_no, kind: "pea"),
        currency: wrapper["currency"].presence || currency,
        current_balance: positions_total.nil? || cash.nil? ? pea&.current_balance : positions_total + cash.to_d,
        cash_balance: cash || 0,
        positions: positions,
        events: Array(data["events"]),
        topic_event_ids: data["timeline_topic_event_ids"],
        instrument_symbols: data["instrument_symbols"],
        unresolved_symbol_isins: data["unresolved_symbol_isins"],
        warnings: Array(wrapper["position_warnings"]),
        domain_statuses: domain_statuses.merge(
          "portfolio" => portfolio_ok ? "success" : "failed",
          "cash" => cash_ok ? "success" : "failed"
        ),
        keep_event: ->(event) { tax_wrapper_event?(event, pea_cash_ids) || pea_transfer_event?(event) }
      )
    end

    # One PEA per login. When this sync could not list the account pairs, a
    # stored PEA still takes its new timeline events and keeps its last
    # positions and cash; otherwise they would land nowhere.
    def pea_wrappers(wrappers)
      return wrappers.first(1) if wrappers.any?

      pea = trade_republic_item.trade_republic_accounts.find_by(kind: "pea")
      sec_acc_no = pea&.trade_republic_account_id.to_s.delete_prefix("pea:").presence
      return [] unless sec_acc_no

      [ { "securities_account_id" => sec_acc_no, "domain_statuses" => {}, "positions" => [], "position_warnings" => [] } ]
    end

    # Cash account numbers of the PEA: from this sync, and from the events
    # stored on the PEA account, so its events stay off the primary account
    # when a sync fails to list the account pairs.
    def tax_wrapper_cash_account_ids(wrappers)
      ids = wrappers.filter_map { |wrapper| wrapper["cash_account_id"].to_s.presence }
      pea = trade_republic_item.trade_republic_accounts.find_by(kind: "pea")
      stored = Array(pea&.raw_timeline_payload).filter_map do |event|
        next unless event.is_a?(Hash)
        next if pea_transfer_event?(event)

        (event["cashAccountNumber"] || event[:cashAccountNumber]).to_s.presence
      end
      (ids + stored).uniq.to_set
    end

    def tax_wrapper_event?(event, pea_cash_ids)
      return false unless event.is_a?(Hash) && pea_cash_ids.any?

      pea_cash_ids.include?((event["cashAccountNumber"] || event[:cashAccountNumber]).to_s)
    end

    def pea_transfer_event?(event)
      return false unless event.is_a?(Hash)

      TradeRepublicAccount::DataHelpers::PEA_TRANSFER_EVENT_TYPES.include?((event["eventType"] || event[:eventType]).to_s)
    end

    # Crypto gets its own account because Sure has a Crypto account type.
    # It reads its positions and trades from the portfolio payloads, so only
    # its balance is stored here. Created once the portfolio holds or traded
    # crypto; it stays unlinked until the user sets it up.
    def upsert_crypto_account(account_id, currency, domain_statuses)
      portfolio = trade_republic_item.trade_republic_accounts.find_by(kind: "portfolio")
      crypto = trade_republic_item.trade_republic_accounts.find_by(kind: "crypto")
      return if crypto.nil? && !holds_or_traded_crypto?(portfolio)

      crypto ||= trade_republic_item.trade_republic_accounts.build(kind: "crypto")

      crypto.assign_attributes(
        trade_republic_account_id: "crypto:#{account_id}",
        name: build_account_name(account_id, kind: "crypto"),
        currency: currency,
        cash_balance: 0
      )
      if domain_statuses["portfolio"] == "success"
        crypto.current_balance = positions_value(crypto_positions(portfolio), fallback: crypto.current_balance)
      end
      crypto.save!
    end

    def holds_or_traded_crypto?(portfolio)
      return false unless portfolio

      crypto_positions(portfolio).any? || Array(portfolio.raw_timeline_payload).any? do |event|
        detail = event.is_a?(Hash) ? (event["detail"] || event[:detail]) : nil
        detail.is_a?(Hash) && TradeRepublicAccount.crypto_isin?(detail["isin"] || detail[:isin])
      end
    end

    def crypto_positions(portfolio)
      Array(portfolio&.raw_positions_payload).select { |position| TradeRepublicAccount.crypto_position?(position) }
    end

    def upsert_kind(kind:, external_id:, name:, currency:, current_balance:, cash_balance:, positions:, events:, instrument_symbols:, warnings:, domain_statuses:, topic_event_ids: nil, unresolved_symbol_isins: [], keep_event: nil)
      tr_account = trade_republic_item.trade_republic_accounts.find_by(trade_republic_account_id: external_id) ||
                    trade_republic_item.trade_republic_accounts.find_or_initialize_by(kind: kind)
      portfolio_status = domain_statuses["portfolio"]
      cash_status = domain_statuses["cash"]
      timeline_status = domain_statuses["timeline"]
      domain_status = %w[portfolio pea].include?(kind) ? portfolio_status : cash_status
      capped_topics = []
      attrs = {
        trade_republic_account_id: external_id,
        name: name,
        currency: currency
      }

      if kind == "pea"
        attrs[:cash_balance] = cash_balance if cash_status != "failed"
        attrs[:current_balance] = current_balance unless current_balance.nil?
        if portfolio_status != "failed"
          attrs[:raw_positions_payload] = merge_position_prices(tr_account.raw_positions_payload, positions)
          attrs[:holdings_snapshot_complete] = portfolio_status == "success" && Array(warnings).empty?
          attrs[:last_positions_sync] = Time.current
        end
      elsif domain_status != "failed"
        if kind == "portfolio"
          attrs[:current_balance] = portfolio_status == "success" ? current_balance : tr_account.current_balance
          attrs[:cash_balance] = cash_balance
          attrs[:raw_positions_payload] = merge_position_prices(tr_account.raw_positions_payload, positions)
          attrs[:holdings_snapshot_complete] = portfolio_status == "success" && Array(warnings).empty?
          attrs[:last_positions_sync] = Time.current
        else
          attrs[:current_balance] = current_balance
          attrs[:cash_balance] = cash_balance
        end
      end

      if timeline_status != "failed"
        # Merge every fetched event before routing, so a stored copy picks up
        # the cash account number it lacked (e.g. a PEA trade stored on the
        # primary account before the PEA existed) and then leaves.
        merged = merge_timeline_events(tr_account.raw_timeline_payload, events)
        incoming = events
        if keep_event
          merged = merged.select { |event| keep_event.call(event) }
          incoming = Array(events).select { |event| keep_event.call(event) }
        end
        apply_instrument_symbols!(merged, instrument_symbols)
        stamp_symbol_lookup_attempts!(merged, unresolved_symbol_isins)
        # Drop order executions before the size cap so they never crowd out
        # cash events on the cash account.
        merged = merged.reject { |event| event_category(event) == "orderExecution" } if kind == "cash"
        capped_topics = capped_timeline_topics(merged, existing: tr_account.raw_timeline_payload, incoming: incoming, topic_event_ids: topic_event_ids)
        attrs[:raw_timeline_payload] = merged.last(MAX_TIMELINE_EVENTS)
      end

      tr_account.assign_attributes(attrs)
      tr_account.save!
      capped_topics
    end

    def normalized_domain_statuses(data)
      explicit = data["domain_statuses"]
      return explicit.stringify_keys if explicit.is_a?(Hash)

      {
        "account_metadata" => data["account"].present? ? "success" : "failed",
        "cash" => data.key?("cash") && data["cash"].present? ? "success" : "failed",
        "portfolio" => data.key?("positions") ? "success" : "failed",
        "timeline" => data.key?("events") ? "success" : "failed",
        "instrument_metadata" => position_warnings(data).empty? ? "success" : "partial"
      }
    end

    def position_warnings(data)
      return Array(data["position_warnings"]) if data.key?("position_warnings")
      return [] if data.key?("domain_statuses")

      Array(data["warnings"]).grep(/price unavailable/i)
    end

    def merge_position_prices(existing, incoming)
      previous_prices = Array(existing).to_h do |position|
        [ position["isin"], position["price"] ]
      end
      Array(incoming).map do |position|
        position["price"].present? ? position : position.merge("price" => previous_prices[position["isin"]])
      end
    end

    # A previous implementation could persist the newest cursor while
    # dropping the actual event payload. Force one full timeline fetch in
    # that state so historical data can be recovered instead of remaining
    # permanently invisible.
    def force_full_timeline_fetch?
      return false if trade_republic_item.newest_event_id.blank?

      portfolio_accounts = trade_republic_item.trade_republic_accounts.select(&:portfolio?)
      portfolio_accounts.any? { |account| Array(account.raw_timeline_payload).blank? }
    end

    # Incomplete trade-detail events, complete trades without a price read from
    # the detail (missing, or derived from the rounded total) and dividends
    # without their detail, in the client's backlog order.
    def events_needing_detail_enrichment
      securities_timeline_events
        .select do |event|
          Provider::TradeRepublicClient.incomplete_trade_detail_event?(event) ||
            Provider::TradeRepublicClient.trade_detail_needs_price_backfill?(event) ||
            Provider::TradeRepublicClient.dividend_detail_missing?(event)
        end
        .sort_by { |event| Provider::TradeRepublicClient.detail_backfill_sort_key(event) }
        .first(Provider::TradeRepublicClient::MAX_TIMELINE_DETAILS)
    end

    # Sold / historical trade ISINs that already have complete details but still
    # lack an exchange ticker. Incremental syncs stop at newest_event_id, so
    # these must be passed explicitly for instrument lookup.
    def isins_needing_symbol_lookup
      securities_timeline_events.filter_map do |event|
        isin = Provider::TradeRepublicClient.symbol_lookup_isin(event)
        isin if isin && Provider::TradeRepublicClient.symbol_lookup_due?(event)
      end.uniq.first(Provider::TradeRepublicClient::MAX_INSTRUMENT_LOOKUPS)
    end

    # Exchange tickers stored by earlier syncs; the client skips the
    # instrument subscription for these positions.
    def stored_instrument_symbols
      positions = securities_accounts.flat_map { |account| Array(account.raw_positions_payload) }
      return {} if positions.empty?

      Provider::TradeRepublicClient.instrument_symbols_from_positions(positions)
    end

    # The accounts that store trades and positions: the primary portfolio and
    # the PEA.
    def securities_accounts
      @securities_accounts ||= trade_republic_item.trade_republic_accounts.where(kind: %w[portfolio pea]).to_a
    end

    def securities_timeline_events
      securities_accounts
        .flat_map { |account| Array(account.raw_timeline_payload) }
        .uniq { |event| event.is_a?(Hash) ? (event["id"] || event[:id]).presence || event : event }
    end

    # Advance the list cursor whenever timeline pagination finished, even when
    # a detail backlog remains for later syncs. The per-topic newest events in
    # timeline_cursors take precedence; this column seeds topics without
    # their own state and triggers the forced full fetch.
    def timeline_cursor_for(data, domain_statuses)
      pagination_complete = if data.key?("timeline_pagination_complete")
        data["timeline_pagination_complete"]
      else
        domain_statuses["timeline"] == "success"
      end
      return trade_republic_item.newest_event_id unless pagination_complete
      return trade_republic_item.newest_event_id if data["newest_event_id"].blank?

      data["newest_event_id"]
    end

    # Per-topic newest event and history backfill position for the next
    # sync. Kept as-is when the timeline failed so no progress is lost. Once
    # the stored history is full, a topic whose fetched events were dropped
    # would lose its older pages straight away, so its history backfill stops.
    def timeline_cursors_for(data, domain_statuses, capped_topics:)
      stored = trade_republic_item.timeline_cursors
      return stored if domain_statuses["timeline"] == "failed" || data["timeline_cursors"].nil?

      cursors = data["timeline_cursors"].to_h
      return cursors if capped_topics.empty?

      Provider::TradeRepublicClient.stop_timeline_history_backfills(cursors, topics: capped_topics)
    end

    def importer_warnings(capped_topics:)
      return [] if capped_topics.empty?

      [ "timeline history exceeds #{MAX_TIMELINE_EVENTS} events; older history is not imported" ]
    end

    # The topics whose events, fetched for the first time this sync, the size
    # cap would discard, i.e. whose history reaches further back than can be
    # stored. A dropped event that can't be traced to a topic (no id, or no
    # per-topic ids from the provider) counts against every topic.
    def capped_timeline_topics(merged, existing:, incoming:, topic_event_ids:)
      overflow = merged.size - MAX_TIMELINE_EVENTS
      return [] unless overflow.positive?

      existing_keys = Array(existing).filter_map { |event| timeline_event_key(event) }.to_set
      fetched_keys = Array(incoming).filter_map { |event| timeline_event_key(event) }.reject { |key| existing_keys.include?(key) }.to_set
      topics_by_id = Hash.new { |hash, id| hash[id] = [] }
      topic_event_ids.to_h.each { |topic, ids| Array(ids).each { |id| topics_by_id[id.to_s] << topic } }

      merged.first(overflow).flat_map do |event|
        next [] unless fetched_keys.include?(timeline_event_key(event))

        topics = topics_by_id.fetch(event_id(event).to_s, [])
        topics.presence || Provider::TradeRepublicClient::TIMELINE_TOPICS
      end.uniq
    end

    # Matches how merge_timeline_events collapses events: by id, or by the
    # whole event when it has none.
    def timeline_event_key(event)
      return unless event.is_a?(Hash)

      event_id(event) || event.as_json
    end

    def event_id(event)
      return unless event.is_a?(Hash)

      (event["id"] || event[:id]).presence
    end

    def merge_timeline_events(existing, incoming)
      events_by_id = {}
      (Array(existing) + Array(incoming)).each do |event|
        next unless event.is_a?(Hash)

        event = event.with_indifferent_access
        key = event[:id].presence || event
        events_by_id[key] = prefer_richer_timeline_event(events_by_id[key], event)
      end
      events_by_id.values.sort_by { |event| event[:timestamp].to_s }
    end

    # Stamp exchange tickers onto timeline details for ISINs that were resolved
    # during sync (including fully sold holdings no longer in the portfolio).
    def apply_instrument_symbols!(events, instrument_symbols)
      return events if instrument_symbols.blank?

      symbols = instrument_symbols.each_with_object({}) do |(isin, mapping), map|
        next if isin.blank? || !mapping.is_a?(Hash)

        entry = mapping.stringify_keys
        symbol = entry["symbol"].to_s.strip.presence
        exchange_slug = entry["exchange_slug"].to_s.strip.upcase.presence
        next if symbol.blank? || exchange_slug.blank?
        next if symbol.casecmp?(isin.to_s)

        map[isin.to_s] = { "symbol" => symbol, "exchange_slug" => exchange_slug }
      end
      return events if symbols.empty?

      Array(events).each do |event|
        next unless event.is_a?(Hash)

        detail = event[:detail] || event["detail"]
        next unless detail.is_a?(Hash)

        detail = detail.with_indifferent_access
        isin = detail[:isin].to_s.presence
        next if isin.blank?

        mapping = symbols[isin]
        next unless mapping

        current_symbol = detail[:symbol].to_s.strip.presence
        usable_symbol = current_symbol.present? && !current_symbol.casecmp?(isin)
        detail[:symbol] = mapping["symbol"] unless usable_symbol
        detail[:exchange_slug] = mapping["exchange_slug"] if detail[:exchange_slug].to_s.strip.blank?

        if event.respond_to?(:[]=)
          event[:detail] = detail
        end
      end

      events
    end

    def stamp_symbol_lookup_attempts!(events, unresolved_isins)
      isins = Array(unresolved_isins).map(&:to_s).to_set
      return events if isins.empty?

      now = Time.current.iso8601
      Array(events).each do |event|
        next unless event.is_a?(Hash)

        detail = event[:detail] || event["detail"]
        next unless detail.is_a?(Hash)

        detail = detail.with_indifferent_access
        next unless isins.include?(detail[:isin].to_s)

        detail[Provider::TradeRepublicClient::SYMBOL_LOOKUP_FIRST_ATTEMPTED_AT_KEY] ||= now
        detail[Provider::TradeRepublicClient::SYMBOL_LOOKUP_ATTEMPTED_AT_KEY] = now
        event[:detail] = detail
      end

      events
    end

    def prefer_richer_timeline_event(previous, incoming)
      return incoming if previous.blank?
      return previous if incoming.blank?

      previous = previous.with_indifferent_access
      incoming = incoming.with_indifferent_access
      merged = previous.merge(incoming)
      merged[:category] = incoming[:category].presence || previous[:category]
      merged[:eventType] = incoming[:eventType].presence || previous[:eventType]
      merged[:detail] = prefer_richer_timeline_detail(previous[:detail], incoming[:detail])
      Provider::TradeRepublicTimelineEvent.merge_lifecycle_fields!(merged, previous, incoming)
      # compact drops nil only; boolean false for deleted/hidden must survive.
      merged.compact
    end

    def prefer_richer_timeline_detail(previous, incoming)
      previous = previous.is_a?(Hash) ? previous.with_indifferent_access : {}.with_indifferent_access
      incoming = incoming.is_a?(Hash) ? incoming.with_indifferent_access : {}.with_indifferent_access
      return previous.presence if incoming.blank?
      return incoming.presence if previous.blank?

      previous.merge(incoming) { |_key, old_value, new_value| new_value.presence || old_value }.presence
    end

    def event_category(event)
      return if event.blank?

      event = event.with_indifferent_access if event.respond_to?(:with_indifferent_access)
      event[:category].to_s
    end

    # Exact decimal math: cash + Σ(quantity × price). Positions lacking a
    # validated price remain visible in the raw payload but contribute zero
    # until Trade Republic provides a current quote.
    def cash_balance(data)
      parse_decimal(data.dig("cash", "amount")) ||
        parse_decimal(data.dig("cash", "value")) || BigDecimal("0")
    end

    def portfolio_balance(data, fallback: nil)
      positions_value(Array(data["positions"]), fallback: fallback)
    end

    def positions_value(positions, fallback: nil)
      return BigDecimal("0") if positions.empty?

      values = positions.map do |position|
        quantity = parse_decimal(position["quantity"])
        price = parse_decimal(position["price"])
        next if quantity.nil? || price.nil?

        quantity * price
      end

      return fallback if fallback.present? && values.any?(&:nil?)

      values.compact.sum(BigDecimal("0"))
    end

    def build_account_name(account_id, kind:)
      base = I18n.t("trade_republic_items.defaults.name")
      suffix = { "cash" => "Cash", "crypto" => "Crypto", "pea" => "PEA" }.fetch(kind, "Portfolio")
      account_id.present? ? "#{base} #{suffix} (#{account_id})" : "#{base} #{suffix}"
    end

    def record_provider_warnings(warnings)
      Array(warnings).uniq.each do |warning|
        DebugLogEntry.capture(
          category: "sync",
          level: "warn",
          message: "Trade Republic sync warning: #{warning}",
          source: "trade_republic",
          family: trade_republic_item.family,
          provider_key: "trade_republic",
          metadata: { trade_republic_item_id: trade_republic_item.id }
        )
      end
    end

    def parse_decimal(value)
      return nil if value.blank?
      decimal = BigDecimal(value.to_s)
      decimal if decimal.finite?
    rescue ArgumentError
      nil
    end
end
