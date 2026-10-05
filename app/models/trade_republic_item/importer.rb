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
      unless domain_statuses["account_metadata"] == "success"
        raise Provider::TradeRepublicClient::MalformedResponse,
          "Trade Republic account metadata was not fetched successfully"
      end

      # Anti-duplication: the client returns per-envelope `accounts` and still
      # mirrors the default envelope under the legacy singular keys. Only
      # synthesise a legacy envelope when `accounts` is absent, otherwise the
      # default portfolio would be upserted twice per sync.
      envelopes = data["accounts"].presence || [ legacy_envelope(data, domain_statuses: domain_statuses) ]

      envelopes.each do |envelope|
        upsert_envelope(envelope, data, domain_statuses)
      end

      default_envelope = envelopes.find { |envelope| envelope["kind"] == "portfolio" } || envelopes.first
      upsert_crypto_account(
        default_envelope["brokerage_account_id"],
        default_envelope["currency"].presence || trade_republic_item.currency.presence || trade_republic_item.family.currency,
        domain_statuses
      )
    end

    # One securities envelope and its cash pocket. The TR timeline is user-wide,
    # so each envelope is fed only the events routed to it (see envelope_events)
    # and the per-envelope statuses decide which slices may be overwritten.
    def upsert_envelope(envelope, data, domain_statuses)
      kind = envelope["kind"]
      account_id = envelope["brokerage_account_id"].presence
      if account_id.blank?
        raise Provider::TradeRepublicClient::MalformedResponse,
          "Trade Republic response did not contain a brokerage account ID"
      end

      currency = envelope["currency"].presence ||
                 trade_republic_item.currency.presence ||
                 trade_republic_item.family.currency
      events = envelope_events(envelope, data["events"])
      statuses = {
        "portfolio" => envelope["positions_status"].presence || domain_statuses["portfolio"],
        "cash" => envelope["cash_status"].presence || domain_statuses["cash"],
        "timeline" => domain_statuses["timeline"]
      }
      existing = trade_republic_item.trade_republic_accounts.find_by(kind: kind)

      # The PEA keeps its cash pocket inside the securities account (French law
      # keeps sale proceeds and interest in the wrapper), so it has no separate
      # cash account; its cash balance rides on the same row.
      upsert_kind(
        kind: kind,
        external_id: account_id,
        name: build_account_name(account_id, kind: kind),
        currency: currency,
        current_balance: positions_value(Array(envelope["positions"]), fallback: existing&.current_balance),
        cash_balance: kind == "pea" ? cash_balance(envelope["cash"]) : 0,
        positions: Array(envelope["positions"]),
        events: events,
        instrument_symbols: data["instrument_symbols"],
        unresolved_symbol_isins: data["unresolved_symbol_isins"],
        warnings: Array(envelope["position_warnings"]),
        domain_statuses: statuses
      )

      return if kind == "pea"

      # Default envelope: cash settles on its own Depository account. Pass every
      # routed event into the cash merge, including orderExecution, so a newly
      # categorized savings-plan event can replace its older unmapped cash copy.
      upsert_kind(
        kind: "cash",
        external_id: "cash:#{account_id}",
        name: build_account_name(account_id, kind: "cash"),
        currency: currency,
        current_balance: cash_balance(envelope["cash"]),
        cash_balance: cash_balance(envelope["cash"]),
        positions: [],
        events: events,
        instrument_symbols: data["instrument_symbols"],
        warnings: [],
        domain_statuses: statuses
      )
    end

    # Events carry the envelope they settled on. Unroutable events (no
    # envelope_kind) stay on the default portfolio so a single-envelope login
    # keeps storing the whole timeline under the same account as before.
    def envelope_events(envelope, events)
      kind = envelope["kind"]
      Array(events).select do |event|
        next false unless event.is_a?(Hash)

        routed = event["envelope_kind"].presence || event[:envelope_kind].presence
        routed.present? ? routed == kind : kind == "portfolio"
      end
    end

    # Rebuilds the legacy singular payload as one portfolio envelope so older
    # provider responses and already-stored shapes flow through the same
    # per-envelope path.
    def legacy_envelope(data, domain_statuses:)
      {
        "kind" => "portfolio",
        "brokerage_account_id" => data.dig("account", "brokerage_account_id"),
        "currency" => data.dig("account", "currency"),
        "positions" => Array(data["positions"]),
        "position_warnings" => position_warnings(data),
        "positions_status" => domain_statuses["portfolio"],
        "cash_status" => domain_statuses["cash"],
        "cash" => data["cash"]
      }
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

    def upsert_kind(kind:, external_id:, name:, currency:, current_balance:, cash_balance:, positions:, events:, instrument_symbols:, warnings:, domain_statuses:, unresolved_symbol_isins: [])
      tr_account = trade_republic_item.trade_republic_accounts.find_by(trade_republic_account_id: external_id) ||
                    trade_republic_item.trade_republic_accounts.find_or_initialize_by(kind: kind)
      securities_kind = TradeRepublicAccount::SECURITIES_KINDS.include?(kind)
      payload_status = domain_statuses[securities_kind ? "portfolio" : "cash"]
      timeline_status = domain_statuses["timeline"]
      attrs = {
        trade_republic_account_id: external_id,
        name: name,
        currency: currency
      }

      if payload_status != "failed"
        if securities_kind
          attrs[:current_balance] = payload_status == "success" ? current_balance : tr_account.current_balance
          attrs[:cash_balance] = cash_balance
          attrs[:raw_positions_payload] = merge_position_prices(tr_account.raw_positions_payload, positions)
          attrs[:holdings_snapshot_complete] = payload_status == "success" && Array(warnings).empty?
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
        merged = merged.reject { |event| event_category(event) == "orderExecution" } if TradeRepublicAccount::CASH_KINDS.include?(kind)
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
      # permanently invisible. A newly seen PEA envelope is blank too, and its
      # history sits behind the same user-wide timeline cursor.
      securities_accounts = trade_republic_item.trade_republic_accounts.select do |account|
        %w[portfolio pea].include?(account.kind)
      end
      return if securities_accounts.any? { |account| Array(account.raw_timeline_payload).blank? }

      trade_republic_item.newest_event_id
    end

    # Incomplete trade-detail events and complete trades still missing a share
    # price (stored before execution price/fees were parsed). Oldest first so
    # repeated syncs progressively drain historical starvation. Trades routed
    # to a PEA envelope are stored on the pea account, so both are scanned.
    def events_needing_detail_enrichment
      events = securities_timeline_events
      return [] if events.empty?

      events
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
      securities_timeline_events.filter_map do |event|
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
    # instrument subscription for these positions. PEA positions are stored on
    # their own account, so both envelopes must contribute or their tickers are
    # re-resolved on every sync.
    def stored_instrument_symbols
      positions = trade_republic_accounts_for_securities.flat_map do |account|
        Array(account.raw_positions_payload)
      end
      return {} if positions.empty?

      Provider::TradeRepublicClient.instrument_symbols_from_positions(positions)
    end

    # Portfolio and PEA store their own positions and routed trades; the
    # default portfolio and the PEA wrapper are separate securities envelopes.
    def trade_republic_accounts_for_securities
      trade_republic_item.trade_republic_accounts.where(kind: %w[portfolio pea])
    end

    def securities_timeline_events
      trade_republic_accounts_for_securities.flat_map do |account|
        Array(account.raw_timeline_payload)
      end
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

    # Exact decimal math. Cash comes from the envelope's cash pocket, not the
    # singular top-level payload.
    def cash_balance(cash)
      parse_decimal(cash&.dig("amount")) ||
        parse_decimal(cash&.dig("value")) || BigDecimal("0")
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
      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
