module TradeRepublicAccount::DataHelpers
  extend ActiveSupport::Concern

  # Timeline event categories Trade Republic emits. Only explicitly mapped
  # categories are imported; anything unknown is skipped and recorded rather
  # than guessed into a transaction.
  CATEGORY_DEPOSIT = "PAYMENT_RECEIVED"
  CATEGORY_WITHDRAWAL = "POC_CREATED"
  CATEGORY_INTEREST = "INTEREST_PAYOUT_CREATED"
  CATEGORY_DIVIDEND = "DIVIDEND"
  KNOWN_ACTIVITY_CATEGORIES = [ CATEGORY_DEPOSIT, CATEGORY_WITHDRAWAL, CATEGORY_INTEREST, CATEGORY_DIVIDEND, "orderExecution" ].freeze

  TRANSFER_EVENT_TYPES = %w[
    PAYMENT_INBOUND PAYMENT_OUTBOUND INCOMING_TRANSFER OUTGOING_TRANSFER
    INCOMING_TRANSFER_DELEGATION OUTGOING_TRANSFER_DELEGATION
  ].freeze

  # Administrative / non-financial timelineActivityLog rows. These stay in the
  # stored payload for audit but must not import, warn, or inflate unknown counts.
  IGNORED_EVENT_TYPES = %w[
    ADDRESS_CHANGED
    PIN_CHANGED
    EMAIL_VALIDATED
    DEVICE_RESET
    CUSTOMER_CREATED
    SECURITIES_ACCOUNT_CREATED
    REFERENCE_ACCOUNT_CHANGED
    PUK_CREATED
    DOCUMENTS_ACCEPTED
    DOCUMENTS_CREATED
    EX_POST_COST_REPORT_CREATED
    TAX_YEAR_END_REPORT_CREATED
    QUARTERLY_REPORT
    QUARTERLY_NET_WORTH_STATEMENT_CREATED
    CARD_VERIFICATION
    ORDER_CANCELED
    ORDER_REJECTED
    TRADING_ORDER_CANCELLED
    TRADING_ORDER_REJECTED
    SSP_CORPORATE_ACTION_INFORMATIVE
    SSP_CORPORATE_ACTION_ACTIVITY
    SSP_CORPORATE_ACTION_INSTRUCTION
    SSP_CORPORATE_ACTION_UPCOMING
    CSX_CHAT_ACTIVITY
    GENERAL_MEETING
    STOCK_PERK_REFUNDED
    PRIVATE_MARKETS_SUITABILITY_QUIZ_COMPLETED
    TRADING_SAVINGSPLAN_EXECUTION_FAILED
  ].freeze

  # Timeline rows that omit eventType/category but are clearly administrative.
  # Titles are compared case-insensitively after strip.
  IGNORED_TITLES = [
    "legal documents"
  ].freeze

  NON_IMPORTABLE_STATUSES = %w[
    DECLINED
    REJECTED
    CANCELLED
    CANCELED
    FAILED
    ERROR
  ].freeze

  DECLINED_SUBTITLE_PATTERN = /declin|failed|reject|cancel/i
  LIFECYCLE_KEYS = %w[status deleted hidden badge].freeze

  class << self
    # Returns :financial, :ignored, or :unknown.
    def classify_timeline_event(event)
      return :unknown unless event.is_a?(Hash)

      event = event.with_indifferent_access
      event_type = event[:eventType].to_s
      return :ignored if IGNORED_EVENT_TYPES.include?(event_type)
      return :ignored if ignored_title?(event)

      category = resolved_category(event)
      return :financial if KNOWN_ACTIVITY_CATEGORIES.include?(category)

      :unknown
    end

    def ignored_title?(event)
      title = event[:title].to_s.strip.downcase
      title.present? && IGNORED_TITLES.include?(title)
    end

    def importable_timeline_event?(event)
      return false unless event.is_a?(Hash)
      return false unless classify_timeline_event(event) == :financial
      return false if lifecycle_blocks_import?(event)

      true
    end

    def lifecycle_blocks_import?(event)
      return false unless event.is_a?(Hash)

      event = event.with_indifferent_access
      return true if truthy_flag?(event[:deleted])

      status = event[:status].to_s.upcase
      return true if NON_IMPORTABLE_STATUSES.include?(status)
      return true if status.blank? && declined_subtitle?(event)

      false
    end

    def non_importable_reason(event)
      return nil unless event.is_a?(Hash)

      event = event.with_indifferent_access
      return "deleted" if truthy_flag?(event[:deleted])

      status = event[:status].to_s.upcase
      return "status:#{status.downcase}" if NON_IMPORTABLE_STATUSES.include?(status)
      return "subtitle" if status.blank? && declined_subtitle?(event)
      return "ignored" if classify_timeline_event(event) == :ignored
      return "unknown" if classify_timeline_event(event) == :unknown

      nil
    end

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

    def resolved_category(event)
      event = event.with_indifferent_access
      event[:category].to_s.presence ||
        Provider::TradeRepublicClient::EVENT_TYPE_CATEGORIES[event[:eventType].to_s]
    end

    def truthy_flag?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def declined_subtitle?(event)
      event = event.with_indifferent_access
      [ event[:subtitle], event[:badge], event[:title] ].compact.any? do |value|
        value.to_s.match?(DECLINED_SUBTITLE_PATTERN)
      end
    end

    def timeline_event_key(event)
      event = event.with_indifferent_access
      return event[:id].to_s if event[:id].present?

      [ event[:timestamp], event[:eventType], event[:title], event[:subtitle] ].map(&:to_s).join("|")
    end

    def merge_lifecycle_fields!(merged, previous, incoming)
      previous = previous.stringify_keys
      incoming = incoming.stringify_keys

      LIFECYCLE_KEYS.each do |key|
        if incoming.key?(key)
          merged[key] = incoming[key]
        elsif previous.key?(key)
          merged[key] = previous[key]
        end
      end

      merged
    end
  end

  private

    def classify_timeline_event(event)
      TradeRepublicAccount::DataHelpers.classify_timeline_event(event)
    end

    def importable_timeline_event?(event)
      TradeRepublicAccount::DataHelpers.importable_timeline_event?(event)
    end

    def lifecycle_blocks_import?(event)
      TradeRepublicAccount::DataHelpers.lifecycle_blocks_import?(event)
    end

    def non_importable_reason(event)
      TradeRepublicAccount::DataHelpers.non_importable_reason(event)
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

    # Resolve (or create) a Security from a Trade Republic position/trade.
    # Prefer an exact exchange ticker when the client supplied one; otherwise
    # keep the ISIN as ticker but mark the security offline so market-data
    # importers skip it while snapshot prices still value the holding.
    def resolve_security(isin, name, symbol: nil, exchange_slug: nil)
      return nil if isin.blank?

      position = position_metadata_for(isin)
      symbol = symbol.to_s.presence || position&.dig(:symbol)
      exchange_slug = exchange_slug.to_s.presence || position&.dig(:exchange_slug)
      mic = mic_for_exchange_slug(exchange_slug)
      usable_symbol = usable_exchange_symbol(symbol, isin)

      if usable_symbol.present? && mic.present?
        security = resolve_exchange_security(usable_symbol, mic, name)
        rematch_account_from_isin!(isin, security) if security
        return security if security
      end

      resolve_offline_isin_security(isin, name)
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
        ensure_online_price_provider!(existing, price_provider)
        return existing
      end

      confirmed = confirm_exchange_security_with_provider(symbol, mic, name, price_provider)
      return confirmed if confirmed

      create_online_security!(
        ticker: symbol,
        exchange_operating_mic: mic,
        name: name,
        price_provider: price_provider
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by_ticker_and_exchange(ticker: symbol, exchange_operating_mic: mic)
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

      security = Security.find_or_initialize_by_ticker_and_exchange(
        ticker: match.ticker,
        exchange_operating_mic: match.exchange_operating_mic.presence || mic
      )
      security.name = match.name.presence || name.presence || security.name || match.ticker
      security.country_code = match.country_code.presence || country_code_for_mic(mic)
      security.price_provider = price_provider if security.price_provider.blank?
      security.offline = false
      security.offline_reason = nil
      security.save!
      security
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

    def create_online_security!(ticker:, exchange_operating_mic:, name:, price_provider:)
      security = Security.find_or_initialize_by_ticker_and_exchange(
        ticker: ticker,
        exchange_operating_mic: exchange_operating_mic
      )
      security.name = name.presence || security.name || ticker
      security.country_code = country_code_for_mic(exchange_operating_mic)
      security.price_provider = price_provider if price_provider.present? && security.price_provider.blank?
      security.offline = false
      security.offline_reason = nil
      security.save!
      security
    end

    def country_code_for_mic(mic)
      return nil if mic.blank?

      Security::EXCHANGES.dig(mic.to_s.upcase, "country")
    end

    def ensure_online_price_provider!(security, price_provider)
      attrs = {}
      attrs[:offline] = false if security.offline?
      attrs[:offline_reason] = nil if security.offline_reason.present?
      if price_provider.present? && security.price_provider.blank?
        attrs[:price_provider] = price_provider
      end
      security.update!(attrs) if attrs.any?
    end

    def resolve_offline_isin_security(isin, name)
      security = Security.find_by(ticker: isin) ||
        Security.new(ticker: isin)

      security.name = name.presence || security.name || isin
      security.offline = true
      security.save!
      security
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

      from_security = Security.find_by(ticker: isin)
      return unless from_security
      return if from_security.id == to_security.id

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
          # Keep the already-resolved exchange holding; preserve provider
          # tracking from the ISIN row when missing on the target.
          attrs = {}
          attrs[:external_id] = holding.external_id if existing.external_id.blank? && holding.external_id.present?
          attrs[:provider_security_id] = from_security.id if existing.provider_security_id.blank?
          attrs[:account_provider_id] = holding.account_provider_id if existing.account_provider_id.blank? && holding.account_provider_id.present?
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
