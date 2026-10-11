# Classification of normalized Trade Republic timeline events. The client uses
# it for detail budgeting and warnings, the account processors for import
# rules. It lives on the provider side and depends on nothing else, so the
# provider boundary stays one-way.
module Provider::TradeRepublicTimelineEvent
  CATEGORY_ORDER_EXECUTION = "orderExecution"
  CATEGORY_DEPOSIT = "PAYMENT_RECEIVED"
  CATEGORY_WITHDRAWAL = "POC_CREATED"
  CATEGORY_INTEREST = "INTEREST_PAYOUT_CREATED"
  CATEGORY_DIVIDEND = "DIVIDEND"
  KNOWN_ACTIVITY_CATEGORIES = [
    CATEGORY_DEPOSIT, CATEGORY_WITHDRAWAL, CATEGORY_INTEREST, CATEGORY_DIVIDEND, CATEGORY_ORDER_EXECUTION
  ].freeze

  EVENT_TYPE_CATEGORIES = {
    "TRADING_TRADE_EXECUTED" => "orderExecution",
    "TRADE_INVOICE" => "orderExecution",
    "ORDER_EXECUTED" => "orderExecution",
    "CRYPTO_INVOICE" => "orderExecution",
    "SAVINGS_PLAN_EXECUTED" => "orderExecution",
    "TRADING_SAVINGSPLAN_EXECUTED" => "orderExecution",
    # Savings-plan executions between mid-2024 and early 2025 arrive only as
    # invoices; Trade Republic switched to TRADING_SAVINGSPLAN_EXECUTED later.
    # Treat them as order executions so timelineDetailV2 is fetched and the
    # portfolio can import a trade.
    "SAVINGS_PLAN_INVOICE_CREATED" => "orderExecution",
    "PRIVATE_MARKET_FUND_TRADE_EXECUTED" => "orderExecution",
    "IPO_TRADE_EXECUTED" => "orderExecution",
    "BANK_TRANSACTION_INCOMING" => "PAYMENT_RECEIVED",
    "INCOMING_TRANSFER" => "PAYMENT_RECEIVED",
    "INCOMING_TRANSFER_DELEGATION" => "PAYMENT_RECEIVED",
    "PAYMENT_INBOUND" => "PAYMENT_RECEIVED",
    "PAYMENT_INBOUND_SEPA_DIRECT_DEBIT" => "PAYMENT_RECEIVED",
    "PAYMENT_INBOUND_APPLE_PAY" => "PAYMENT_RECEIVED",
    "PAYMENT_INBOUND_GOOGLE_PAY" => "PAYMENT_RECEIVED",
    "BANK_TRANSACTION_OUTGOING" => "POC_CREATED",
    "BANK_TRANSACTION_OUTGOING_DIRECT_DEBIT" => "POC_CREATED",
    "OUTGOING_TRANSFER" => "POC_CREATED",
    "OUTGOING_TRANSFER_DELEGATION" => "POC_CREATED",
    "PAYMENT_OUTBOUND" => "POC_CREATED",
    "CARD_TRANSACTION" => "POC_CREATED",
    "card_successful_transaction" => "POC_CREATED",
    # Trade Republic currently uses CARD_CASH_BACK for some card purchases
    # (for example, Marktkauf), not only for actual cashback credits. The
    # signed provider amount confirms these are cash outflows.
    "CARD_CASH_BACK" => "POC_CREATED",
    "card_refund" => "PAYMENT_RECEIVED",
    "CARD_REFUND" => "PAYMENT_RECEIVED",
    "SPARE_CHANGE_AGGREGATE" => "POC_CREATED",
    "SAVEBACK_AGGREGATE" => "POC_CREATED",
    "BANK_TRANSACTION_OUTGOING_SCHEDULED" => "POC_CREATED",
    "CARD_ATM_WITHDRAWAL" => "POC_CREATED",
    "SSP_CORPORATE_ACTION_CASH" => "DIVIDEND",
    "ssp_corporate_action_invoice_cash" => "DIVIDEND",
    "SSP_CORPORATE_ACTION_CASH_NON_DIVIDEND" => "PAYMENT_RECEIVED",
    "DIVIDEND" => "DIVIDEND",
    "CREDIT" => "DIVIDEND",
    "INTEREST_PAYOUT" => "INTEREST_PAYOUT_CREATED",
    "INTEREST_PAYOUT_CREATED" => "INTEREST_PAYOUT_CREATED",
    "TAX_REFUND" => "PAYMENT_RECEIVED",
    "ssp_tax_correction_invoice" => "PAYMENT_RECEIVED",
    "SSP_TAX_CORRECTION" => "PAYMENT_RECEIVED",
    "CARD_ORDER_FEE" => "POC_CREATED"
  }.freeze

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
    TRADING_ORDER_CREATED
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
    def classify(event)
      return :unknown unless event.is_a?(Hash)

      event = event.with_indifferent_access
      event_type = event[:eventType].to_s
      return :ignored if IGNORED_EVENT_TYPES.include?(event_type)
      return :ignored if ignored_title?(event)

      return :financial if KNOWN_ACTIVITY_CATEGORIES.include?(resolved_category(event))

      :unknown
    end

    def importable?(event)
      return false unless event.is_a?(Hash)
      return false unless classify(event) == :financial
      return false if lifecycle_blocks_import?(event)

      true
    end

    # Explicit signals plus the free-text subtitle heuristic. Blocks import
    # only; destructive reconciliation must use `explicit_lifecycle_block?`.
    def lifecycle_blocks_import?(event)
      return false unless event.is_a?(Hash)
      return true if explicit_lifecycle_block?(event)

      event = event.with_indifferent_access
      event[:status].to_s.blank? && declined_subtitle?(event)
    end

    # Deleted, hidden, or a terminal non-importable status from Trade Republic.
    def explicit_lifecycle_block?(event)
      return false unless event.is_a?(Hash)

      event = event.with_indifferent_access
      return true if truthy_flag?(event[:deleted])
      return true if truthy_flag?(event[:hidden])

      NON_IMPORTABLE_STATUSES.include?(event[:status].to_s.upcase)
    end

    def non_importable_reason(event)
      return nil unless event.is_a?(Hash)

      event = event.with_indifferent_access
      return "deleted" if truthy_flag?(event[:deleted])
      return "hidden" if truthy_flag?(event[:hidden])

      status = event[:status].to_s.upcase
      return "status:#{status.downcase}" if NON_IMPORTABLE_STATUSES.include?(status)
      return "subtitle" if status.blank? && declined_subtitle?(event)
      return "ignored" if classify(event) == :ignored
      return "unknown" if classify(event) == :unknown

      nil
    end

    def resolved_category(event)
      event = event.with_indifferent_access
      event[:category].to_s.presence || EVENT_TYPE_CATEGORIES[event[:eventType].to_s]
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

    private

      def ignored_title?(event)
        title = event[:title].to_s.strip.downcase
        title.present? && IGNORED_TITLES.include?(title)
      end

      def truthy_flag?(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end

      # Only subtitle/badge — never title. Titles are often security or
      # merchant names and can contain substrings like "cancel" without
      # meaning the event itself failed.
      def declined_subtitle?(event)
        [ event[:subtitle], event[:badge] ].compact.any? do |value|
          value.to_s.match?(DECLINED_SUBTITLE_PATTERN)
        end
      end
  end
end
