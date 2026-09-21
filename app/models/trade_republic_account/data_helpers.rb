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

      category = resolved_category(event)
      return :financial if KNOWN_ACTIVITY_CATEGORIES.include?(category)

      :unknown
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

    # Resolve (or create) a Security from a Trade Republic position. The ISIN
    # is the stable provider identifier; ticker matching falls back to it
    # because the securities table has no ISIN column.
    def resolve_security(isin, name)
      return nil if isin.blank?

      Security.find_by(ticker: isin) ||
        Security.create!(ticker: isin, name: name.presence || isin)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: isin)
    end
end
