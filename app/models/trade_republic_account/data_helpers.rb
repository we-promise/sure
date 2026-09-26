module TradeRepublicAccount::DataHelpers
  extend ActiveSupport::Concern

  # Timeline event classification lives in Provider::TradeRepublicTimelineEvent;
  # including it exposes the CATEGORY_* constants to the processors.
  include Provider::TradeRepublicTimelineEvent

  TRANSFER_EVENT_TYPES = %w[
    PAYMENT_INBOUND PAYMENT_OUTBOUND INCOMING_TRANSFER OUTGOING_TRANSFER
    INCOMING_TRANSFER_DELEGATION OUTGOING_TRANSFER_DELEGATION
  ].freeze

  class << self
    # Portfolio is the full timeline; cash is a filtered subset. Prefer portfolio
    # rows, then append cash-only events, deduped by event id.
    def unique_timeline_events(portfolio_events, cash_events = [])
      seen = {}
      result = []

      (Array(portfolio_events) + Array(cash_events)).each do |event|
        next unless event.is_a?(Hash)

        key = timeline_event_key(event)
        next if seen[key]

        seen[key] = true
        result << event
      end

      result
    end

    def timeline_event_key(event)
      event = event.with_indifferent_access
      return event[:id].to_s if event[:id].present?

      [ event[:timestamp], event[:eventType], event[:title], event[:subtitle] ].map(&:to_s).join("|")
    end
  end

  private

    def classify_timeline_event(event)
      Provider::TradeRepublicTimelineEvent.classify(event)
    end

    def importable_timeline_event?(event)
      Provider::TradeRepublicTimelineEvent.importable?(event)
    end

    def lifecycle_blocks_import?(event)
      Provider::TradeRepublicTimelineEvent.lifecycle_blocks_import?(event)
    end

    def non_importable_reason(event)
      Provider::TradeRepublicTimelineEvent.non_importable_reason(event)
    end

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.strip : value.to_s
      return nil if normalized.blank?

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      return nil if value.blank?

      case value
      when DateTime, Time, ActiveSupport::TimeWithZone
        value.to_date
      when Date
        value
      else
        Time.zone.parse(value.to_s)&.to_date || Date.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end

    # Trade Republic exchange slugs → ISO MICs.
    EXCHANGE_SLUG_TO_MIC = {
      "XETR" => "XETR",
      "TDG" => "TGAT",
      "LSX" => "XHAM"
    }.freeze
    OFFLINE_ISIN_REASON = "trade_republic_isin"

    # Resolve (or create) a Security from a Trade Republic position/trade.
    # Prefer an exact exchange ticker when the client supplied one; otherwise
    # keep the ISIN as ticker but mark the security offline so market-data
    # importers skip it while snapshot prices still value the holding.
    def resolve_security(isin, name, symbol: nil, exchange_slug: nil)
      return nil if isin.blank?

      usable_symbol, mic = exchange_listing_for(isin, symbol: symbol, exchange_slug: exchange_slug)
      if usable_symbol
        security = cached_exchange_security(usable_symbol, mic, name)
        rematch_account_from_isin!(isin, security) if security
        return security if security
      end

      resolve_offline_isin_security(isin, name)
    end

    # [symbol, mic] when Trade Republic supplied a usable exchange ticker.
    def exchange_listing_for(isin, symbol: nil, exchange_slug: nil)
      position = position_metadata_for(isin)
      symbol = symbol.to_s.presence || position&.dig(:symbol)
      exchange_slug = exchange_slug.to_s.presence || position&.dig(:exchange_slug)
      mic = mic_for_exchange_slug(exchange_slug)
      usable_symbol = usable_exchange_symbol(symbol, isin)

      [ usable_symbol, mic ] if usable_symbol.present? && mic.present?
    end

    # Pre-resolved by TradeRepublicAccount::SecurityPrefetcher so the provider
    # search runs before Processor opens its transaction.
    def exchange_securities
      @exchange_securities ||= {}
    end

    def cached_exchange_security(symbol, mic, name)
      key = [ symbol, mic ]
      return exchange_securities[key] if exchange_securities[key]

      security = resolve_exchange_security(symbol, mic, name)
      exchange_securities[key] = security if security
      security
    end

    # Timeline trade details contain an ISIN but no exchange symbol. Reuse the
    # metadata fetched for the matching portfolio position so holdings and
    # trades resolve to the same Security.
    def position_metadata_for(isin)
      position = Array(@trade_republic_account&.raw_positions_payload).find do |candidate|
        candidate.is_a?(Hash) && candidate.with_indifferent_access[:isin].to_s == isin.to_s
      end

      position&.with_indifferent_access
    end

    def usable_exchange_symbol(symbol, isin)
      candidate = symbol.to_s.strip.presence
      return nil if candidate.blank?
      return nil if candidate.casecmp?(isin.to_s)

      candidate
    end

    def mic_for_exchange_slug(exchange_slug)
      EXCHANGE_SLUG_TO_MIC[exchange_slug.to_s.strip.upcase].presence
    end

    def resolve_exchange_security(symbol, mic, name)
      price_provider = available_price_provider

      existing = Security.find_by_ticker_and_exchange(
        ticker: symbol,
        exchange_operating_mic: mic
      )
      if existing
        ensure_price_provider!(existing, price_provider)
        return existing
      end

      confirmed = confirm_exchange_security_with_provider(symbol, mic, name, price_provider)
      return confirmed if confirmed

      find_or_create_exchange_security!(
        ticker: symbol,
        exchange_operating_mic: mic,
        name: name,
        price_provider: price_provider
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      existing = Security.find_by_ticker_and_exchange(ticker: symbol, exchange_operating_mic: mic)
      ensure_price_provider!(existing, price_provider) if existing
      existing
    end

    # Exact ticker + MIC only — never fall through to Security::Resolver's
    # fuzzy name search, which can attach the wrong fund.
    def confirm_exchange_security_with_provider(symbol, mic, name, price_provider)
      return nil if price_provider.blank?

      match = Security.search_provider(
        symbol,
        country_code: country_code_for_mic(mic),
        exchange_operating_mic: mic
      ).find { |candidate| provider_ticker_confirms?(candidate.ticker, symbol, candidate.exchange_operating_mic, mic) }

      return nil unless match

      match_mic = match.exchange_operating_mic.presence || mic
      Security.transaction(requires_new: true) do
        security = Security.find_or_initialize_by_ticker_and_exchange(
          ticker: match.ticker,
          exchange_operating_mic: match_mic
        )
        security.name = match.name.presence || name.presence || security.name || match.ticker
        security.country_code = match.country_code.presence || country_code_for_mic(mic)
        security.price_provider = price_provider if security.price_provider.blank?
        security.save!
        security
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      existing = Security.find_by_ticker_and_exchange(ticker: match.ticker, exchange_operating_mic: match_mic)
      if existing
        ensure_price_provider!(existing, price_provider)
        existing
      else
        Rails.logger.warn("TradeRepublicAccount - Provider security confirm failed for #{symbol}/#{mic}: #{e.message}")
        nil
      end
    rescue StandardError => e
      Rails.logger.warn("TradeRepublicAccount - Provider security confirm failed for #{symbol}/#{mic}: #{e.message}")
      nil
    end

    def provider_ticker_confirms?(provider_ticker, symbol, provider_mic, expected_mic)
      return false if provider_ticker.blank?

      canonical_provider = Security.canonical_exchange_operating_mic(provider_mic)
      canonical_expected = Security.canonical_exchange_operating_mic(expected_mic)
      return false if canonical_provider.blank? || canonical_expected.blank?
      return false if canonical_provider != canonical_expected

      ticker = provider_ticker.to_s.upcase
      base = symbol.to_s.upcase
      ticker == base || ticker.start_with?("#{base}.")
    end

    def available_price_provider
      Setting.enabled_securities_providers.find do |provider_key|
        Security.provider_for(provider_key).present?
      end
    end

    def find_or_create_exchange_security!(ticker:, exchange_operating_mic:, name:, price_provider:)
      Security.transaction(requires_new: true) do
        security = Security.find_or_initialize_by_ticker_and_exchange(
          ticker: ticker,
          exchange_operating_mic: exchange_operating_mic
        )
        security.name = name.presence || security.name || ticker
        security.country_code = country_code_for_mic(exchange_operating_mic)
        security.price_provider = price_provider if price_provider.present? && security.price_provider.blank?
        security.save!
        security
      end
    end

    def country_code_for_mic(mic)
      return nil if mic.blank?

      Security::EXCHANGES.dig(mic.to_s.upcase, "country")
    end

    def ensure_price_provider!(security, price_provider)
      attrs = {}
      if price_provider.present? && security.price_provider.blank?
        attrs[:price_provider] = price_provider
      end
      security.update!(attrs) if attrs.any?
    end

    # Securities are shared across families, so an existing ISIN row is reused
    # as-is: its offline state belongs to whichever flow set it.
    def resolve_offline_isin_security(isin, name)
      existing = Security.find_by(ticker: isin)
      return existing if existing

      Security.transaction(requires_new: true) do
        Security.new(
          ticker: isin,
          name: name.presence || isin,
          offline: true,
          offline_reason: OFFLINE_ISIN_REASON
        ).tap(&:save!)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: isin)
    end

    # Securities are global. When an account previously stored the ISIN as the
    # ticker, move only this account's holdings and trades onto the resolved
    # exchange security instead of rewriting the shared ISIN row.
    #
    # Holdings use a unique index on (account_id, security_id, date, currency).
    # Blind update_all can raise RecordNotUnique when today's exchange holding
    # already exists (e.g. HoldingsProcessor imported it before Activities
    # rematch), which aborts the outer Processor transaction. Move row-by-row
    # and drop the stale ISIN duplicate on collision.
    def rematch_account_from_isin!(isin, to_security)
      return unless account.present? && to_security.present?

      @rematched_isins ||= Set.new
      return unless @rematched_isins.add?([ isin.to_s, to_security.id ])

      from_security = Security.find_by(ticker: isin)
      return unless from_security
      return if from_security.id == to_security.id
      return unless account.holdings.where(security_id: from_security.id).exists? ||
        account.trades.where(security_id: from_security.id).exists?

      rematch_holdings_from_isin!(from_security, to_security)
      account.trades.where(security_id: from_security.id).update_all(
        security_id: to_security.id,
        updated_at: Time.current
      )
    end

    def rematch_holdings_from_isin!(from_security, to_security)
      existing_keys = account.holdings
        .where(security_id: to_security.id)
        .pluck(:date, :currency)
        .to_set

      account.holdings.where(security_id: from_security.id).find_each do |holding|
        key = [ holding.date, holding.currency ]
        if existing_keys.include?(key)
          existing = account.holdings.find_by!(
            security_id: to_security.id,
            date: holding.date,
            currency: holding.currency
          )
          # Both rows are the same position after ISIN→ticker rematch (live
          # exchange holding from HoldingsProcessor vs stale ISIN row). Keep
          # exchange market qty/amount/price — summing would double-count.
          # Merge provider tracking and cost basis from the ISIN row when the
          # exchange row is missing them.
          attrs = {}
          attrs[:external_id] = holding.external_id if existing.external_id.blank? && holding.external_id.present?
          if existing.provider_security_id.blank?
            attrs[:provider_security_id] = holding.provider_security_id.presence || from_security.id
          end
          attrs[:account_provider_id] = holding.account_provider_id if existing.account_provider_id.blank? && holding.account_provider_id.present?
          attrs[:cost_basis] = holding.cost_basis if existing.cost_basis.blank? && holding.cost_basis.present?

          if existing.qty != holding.qty || existing.amount != holding.amount
            DebugLogEntry.capture(
              category: "sync",
              level: "info",
              message: "ISIN rematch collision kept exchange holding market values",
              source: "trade_republic",
              family: account.family,
              provider_key: "trade_republic",
              account: account,
              metadata: {
                from_security_id: from_security.id,
                to_security_id: to_security.id,
                date: holding.date,
                isin_qty: holding.qty,
                isin_amount: holding.amount,
                exchange_qty: existing.qty,
                exchange_amount: existing.amount
              }
            )
          end

          existing.update!(attrs) if attrs.any?
          holding.destroy!
        else
          holding.update!(
            security_id: to_security.id,
            provider_security_id: holding.provider_security_id.presence || from_security.id
          )
          existing_keys << key
        end
      end
    end
end
