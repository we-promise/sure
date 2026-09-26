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
    result = provider.sync(
      session_txt: trade_republic_item.session_blob,
      known_newest_event_id: known_newest_event_id,
      enrich_events: events_needing_detail_enrichment,
      symbol_lookup_isins: isins_needing_symbol_lookup,
      known_instrument_symbols: stored_instrument_symbols
    )

    data = result.data
    domain_statuses = normalized_domain_statuses(data)

    if data["status"] == "session_expired"
      trade_republic_item.update!(status: :requires_update)
      raise Provider::TradeRepublicClient::AuthenticationRequired,
        "Trade Republic session expired. Re-authentication required."
    end

    ActiveRecord::Base.transaction do
      upsert_account(data, domain_statuses: domain_statuses)
      trade_republic_item.update!(
        status: :good,
        newest_event_id: timeline_cursor_for(data, domain_statuses),
        session_blob: data["session_txt"].presence || trade_republic_item.session_blob
      )
    end

    record_provider_warnings(data["warnings"])

    {
      success: true,
      detail_backfill_count: data["detail_backfill_count"].to_i
    }
  end

  private

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

      upsert_kind(
        kind: "portfolio",
        external_id: account_id,
        name: build_account_name(account_id, kind: "portfolio"),
        currency: currency,
        current_balance: portfolio_balance(data, fallback: portfolio_account&.current_balance),
        cash_balance: 0,
        positions: Array(data["positions"]),
        events: data["events"],
        instrument_symbols: data["instrument_symbols"],
        unresolved_symbol_isins: data["unresolved_symbol_isins"],
        warnings: position_warnings(data),
        domain_statuses: domain_statuses
      )
      # Pass every event into the cash merge, including orderExecution. Filtering
      # happens after merge so a newly categorized savings-plan event can replace
      # and remove its older unmapped cash copy.
      upsert_kind(
        kind: "cash",
        external_id: "cash:#{account_id}",
        name: build_account_name(account_id, kind: "cash"),
        currency: currency,
        current_balance: cash_balance(data),
        cash_balance: cash_balance(data),
        positions: [],
        events: Array(data["events"]),
        instrument_symbols: data["instrument_symbols"],
        warnings: [],
        domain_statuses: domain_statuses
      )
    end

    def upsert_kind(kind:, external_id:, name:, currency:, current_balance:, cash_balance:, positions:, events:, instrument_symbols:, warnings:, domain_statuses:, unresolved_symbol_isins: [])
      tr_account = trade_republic_item.trade_republic_accounts.find_by(trade_republic_account_id: external_id) ||
                    trade_republic_item.trade_republic_accounts.find_or_initialize_by(kind: kind)
      portfolio_status = domain_statuses["portfolio"]
      cash_status = domain_statuses["cash"]
      timeline_status = domain_statuses["timeline"]
      domain_status = kind == "portfolio" ? portfolio_status : cash_status
      attrs = {
        trade_republic_account_id: external_id,
        name: name,
        currency: currency
      }

      if domain_status != "failed"
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
        merged = merge_timeline_events(tr_account.raw_timeline_payload, events)
        apply_instrument_symbols!(merged, instrument_symbols)
        stamp_symbol_lookup_attempts!(merged, unresolved_symbol_isins)
        # Drop order executions before the size cap so they never crowd out
        # cash events on the cash account.
        merged = merged.reject { |event| event_category(event) == "orderExecution" } if kind == "cash"
        attrs[:raw_timeline_payload] = merged.last(MAX_TIMELINE_EVENTS)
      end

      tr_account.assign_attributes(attrs)
      tr_account.save!
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

    def known_newest_event_id
      return if trade_republic_item.newest_event_id.blank?

      # A previous implementation could persist the newest cursor while
      # dropping the actual event payload. Force one full timeline fetch in
      # that state so historical data can be recovered instead of remaining
      # permanently invisible.
      portfolio_accounts = trade_republic_item.trade_republic_accounts.select(&:portfolio?)
      return if portfolio_accounts.any? { |account| Array(account.raw_timeline_payload).blank? }

      trade_republic_item.newest_event_id
    end

    # Incomplete trade-detail events and complete trades still missing a share
    # price (stored before execution price/fees were parsed). Oldest first so
    # repeated syncs progressively drain historical starvation.
    def events_needing_detail_enrichment
      portfolio = trade_republic_item.trade_republic_accounts.find_by(kind: "portfolio")
      return [] unless portfolio

      Array(portfolio.raw_timeline_payload)
        .select do |event|
          Provider::TradeRepublicClient.incomplete_trade_detail_event?(event) ||
            Provider::TradeRepublicClient.trade_detail_needs_price_backfill?(event)
        end
        .sort_by { |event| event_timestamp(event) }
        .first(Provider::TradeRepublicClient::MAX_TIMELINE_DETAILS)
    end

    # Sold / historical trade ISINs that already have complete details but still
    # lack an exchange ticker. Incremental syncs stop at newest_event_id, so
    # these must be passed explicitly for instrument lookup.
    def isins_needing_symbol_lookup
      portfolio = trade_republic_item.trade_republic_accounts.find_by(kind: "portfolio")
      return [] unless portfolio

      Array(portfolio.raw_timeline_payload).filter_map do |event|
        next unless event.is_a?(Hash)
        next unless Provider::TradeRepublicClient.requires_trade_detail?(event)
        next unless Provider::TradeRepublicTimelineEvent.importable?(event)

        detail = (event["detail"] || event[:detail])
        next unless detail.is_a?(Hash)

        detail = detail.stringify_keys
        isin = detail["isin"].to_s.presence
        next if isin.blank?

        symbol = detail["symbol"].to_s.strip.presence
        exchange_slug = detail["exchange_slug"].to_s.strip.presence
        usable = symbol.present? && !symbol.casecmp?(isin) && exchange_slug.present?
        next if usable
        next unless Provider::TradeRepublicClient.symbol_lookup_due?(event)

        isin
      end.uniq.first(Provider::TradeRepublicClient::MAX_INSTRUMENT_LOOKUPS)
    end

    # Exchange tickers stored by earlier syncs; the client skips the
    # instrument subscription for these positions.
    def stored_instrument_symbols
      portfolio = trade_republic_item.trade_republic_accounts.find_by(kind: "portfolio")
      return {} unless portfolio

      Provider::TradeRepublicClient.instrument_symbols_from_positions(portfolio.raw_positions_payload)
    end

    def event_timestamp(event)
      return "" unless event.is_a?(Hash)

      (event["timestamp"] || event[:timestamp]).to_s
    end

    # Advance the list cursor whenever timeline pagination finished, even when
    # a detail backlog remains for later syncs.
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
      parse_decimal(data.dig("cash", "available_amount")) ||
        parse_decimal(data.dig("cash", "amount")) ||
        parse_decimal(data.dig("cash", "value")) || BigDecimal("0")
    end

    def portfolio_balance(data, fallback: nil)
      positions = Array(data["positions"])
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
      suffix = kind == "cash" ? "Cash" : "Portfolio"
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
      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
