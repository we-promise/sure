require "bigdecimal"
require "date"
require "digest"
require "json"
require "time"

class ScalableItem::HistoryNormalizer
  MAX_ROWS = 10_000
  MAX_ID_BYTES = 256
  MAX_STATUS_BYTES = 64
  MAX_DESCRIPTION_BYTES = 512
  MAX_DECIMAL_BYTES = 128
  MAX_DATABASE_AMOUNT = BigDecimal("1000000000000000")
  SETTLED_SUMMARY_STATUSES = %w[SETTLED CONFIRMED].freeze
  PENDING_STATES = %w[CREATED REQUESTED PENDING CANCEL_REQUESTED].freeze
  CANCELLED_STATES = %w[CANCELLED EXPIRED REJECTED].freeze
  KNOWN_HISTORY_STATES = (PENDING_STATES + CANCELLED_STATES + [ "SETTLED" ]).freeze

  Result = Data.define(:activities)
  Activity = Data.define(:external_id, :date, :amount, :currency, :name, :metadata)

  def initialize(rows:, portfolio_id:)
    @rows = rows
    @portfolio_id = required_string(portfolio_id, MAX_ID_BYTES)
  end

  def normalize
    history_incomplete! unless @rows.is_a?(Array) && @rows.length <= MAX_ROWS

    source_ids = {}
    activities = @rows.filter_map do |row|
      normalize_row(row, source_ids)
    end

    Result.new(activities: activities.freeze)
  end

  private

    def normalize_row(raw, source_ids)
      row = required_hash(raw)
      source_id = required_string(row["id"], MAX_ID_BYTES)
      history_incomplete! if source_ids[source_id]

      source_ids[source_id] = true
      typename = required_string(row["__typename"], MAX_STATUS_BYTES)
      history_unsupported! unless typename == "BrokerCashTransaction"

      type = required_string(row["type"], MAX_STATUS_BYTES)
      history_unsupported! unless type == "CASH_TRANSACTION"

      currency = required_currency(row["currency"])
      history_unsupported! unless currency == "EUR"

      cash_transaction_type = required_string(row["cashTransactionType"], MAX_STATUS_BYTES)
      history_unsupported! unless %w[DEPOSIT WITHDRAWAL].include?(cash_transaction_type)
      status = optional_string(row["summary_status"], MAX_STATUS_BYTES)

      is_pending = row["isPending"]
      is_cancellation = row["isCancellation"]
      history_incomplete! unless [ true, false ].include?(is_pending) && [ true, false ].include?(is_cancellation)
      return if is_pending || is_cancellation

      states = history_states(row["cashTransactionHistory"])
      return if states.any? { |state| PENDING_STATES.include?(state) || CANCELLED_STATES.include?(state) } && !states.include?("SETTLED")

      history_incomplete! unless states.include?("SETTLED")
      history_incomplete! if states.any? { |state| CANCELLED_STATES.include?(state) }
      history_incomplete! unless SETTLED_SUMMARY_STATUSES.include?(status)

      provider_amount = decimal(row["amount"])
      validate_amount!(provider_amount)
      validate_direction!(cash_transaction_type, provider_amount)
      date = event_date(row["lastEventDateTime"])
      name = description_name(row["description"], cash_transaction_type)

      metadata = {
        "cash_transaction_type" => cash_transaction_type,
        "source_id" => source_id,
        "status" => status
      }

      Activity.new(
        external_id: external_id(source_id),
        date: date,
        amount: (-provider_amount).round(4),
        currency: currency,
        name: name,
        metadata: metadata.freeze
      )
    end

    def history_states(value)
      history_incomplete! unless value.is_a?(Array) && !value.empty?

      value.map do |row|
        event = required_hash(row)
        state = required_string(event["state"], MAX_STATUS_BYTES)
        history_incomplete! unless KNOWN_HISTORY_STATES.include?(state)

        state
      end
    end

    def validate_direction!(cash_transaction_type, provider_amount)
      valid_direction = case cash_transaction_type
      when "DEPOSIT" then provider_amount.positive?
      when "WITHDRAWAL" then provider_amount.negative?
      else false
      end
      history_incomplete! unless valid_direction
    end

    def validate_amount!(value)
      history_incomplete! unless value.finite? && value == value.round(4) && value.abs < MAX_DATABASE_AMOUNT
    end

    def decimal(value)
      history_incomplete! unless value.is_a?(String) || value.is_a?(Numeric)
      history_incomplete! if value.to_s.bytesize > MAX_DECIMAL_BYTES
      history_incomplete! if value.is_a?(Float) && !value.finite?

      amount = BigDecimal(value.to_s)
      history_incomplete! unless amount.finite?

      amount
    rescue ArgumentError, TypeError
      history_incomplete!
    end

    def event_date(value)
      date_time = required_string(value, 128)
      match = date_time.match(/\A(\d{4}-\d{2}-\d{2})T/)
      history_incomplete! unless match

      DateTime.iso8601(date_time)
      Date.iso8601(match[1])
    rescue Date::Error, ArgumentError
      history_incomplete!
    end

    def description_name(value, cash_transaction_type)
      if value.nil?
        return default_name(cash_transaction_type)
      end

      history_incomplete! unless value.is_a?(String) && value.valid_encoding?
      description = value.strip
      return default_name(cash_transaction_type) if description.empty?

      history_incomplete! if description.bytesize > MAX_DESCRIPTION_BYTES || description.match?(/[\u0000-\u001F\u007F]/)

      description
    end

    def default_name(cash_transaction_type)
      cash_transaction_type == "DEPOSIT" ? "Scalable deposit" : "Scalable withdrawal"
    end

    def external_id(source_id)
      digest = Digest::SHA256.hexdigest(JSON.generate([ @portfolio_id, source_id ]))
      "scalable-history-v1:#{digest}"
    end

    def required_hash(value)
      history_incomplete! unless value.is_a?(Hash)

      value
    end

    def required_string(value, max_bytes)
      history_incomplete! unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= max_bytes &&
        value.present? && value == value.strip && !value.match?(/[\u0000-\u001F\u007F]/)

      value
    end

    def optional_string(value, max_bytes)
      return if value.nil? || value == ""

      required_string(value, max_bytes)
    end

    def required_currency(value)
      currency = required_string(value, 3)
      history_incomplete! unless currency.match?(/\A[A-Z]{3}\z/)

      currency
    end

    def history_incomplete!
      raise Provider::Scalable::Error.new(:history_incomplete), cause: nil
    end

    def history_unsupported!
      raise Provider::Scalable::Error.new(:history_unsupported), cause: nil
    end
end
