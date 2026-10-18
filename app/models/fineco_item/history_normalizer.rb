require "bigdecimal"
require "date"
require "digest"
require "json"
require "time"

class FinecoItem::HistoryNormalizer
  BANK_TIME_ZONE = "Europe/Rome".freeze
  EXTERNAL_ID_PREFIX = "fineco-history-v1:".freeze
  ISIN_PATTERN = /\A[A-Z]{2}[A-Z0-9]{9}[0-9]\z/
  ISO_DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
  ISO_LOCAL_TIMESTAMP_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?\z/
  ISO_TIMESTAMP_PATTERN = /\A(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})T(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})(?<fraction>\.\d+)?(?<offset>Z|[+-]\d{2}:\d{2})\z/
  SIGNS = %w[A V].freeze

  Activity = Data.define(
    :date,
    :isin,
    :name,
    :quantity,
    :price,
    :amount,
    :currency,
    :external_id,
    :fingerprint,
    :occurrence,
    :metadata
  ) do
    def inspect
      "#<#{self.class.name} [REDACTED]>"
    end

    alias to_s inspect
  end

  Result = Data.define(:activities, :cohorts) do
    def inspect
      "#<#{self.class.name} [REDACTED]>"
    end

    alias to_s inspect
  end

  def initialize(rows:, bank_scope:)
    @rows = rows
    @bank_scope = bank_scope.to_s.strip
  end

  def normalize
    invalid_data! if @bank_scope.blank? || @bank_scope.bytesize > 256
    unsupported_activity! unless @rows.is_a?(Array)

    drafts = @rows.map { |row| normalize_row(row) }
    occurrences = Hash.new(0)
    activities = drafts.map do |draft|
      fingerprint = fingerprint_for(draft)
      occurrences[fingerprint] += 1
      occurrence = occurrences.fetch(fingerprint)

      Activity.new(
        date: draft.fetch(:date),
        isin: draft.fetch(:isin),
        name: draft.fetch(:name),
        quantity: signed(draft.fetch(:quantity), draft.fetch(:sign)),
        price: draft.fetch(:gross_eur) / draft.fetch(:quantity),
        amount: signed(draft.fetch(:gross_eur), draft.fetch(:sign)),
        currency: "EUR",
        external_id: external_id_for(draft.fetch(:date), fingerprint, occurrence),
        fingerprint: fingerprint,
        occurrence: occurrence,
        metadata: metadata_for(draft, fingerprint, occurrence).freeze
      )
    end

    Result.new(activities: activities.freeze, cohorts: cohorts_for(activities).freeze)
  rescue FinecoItem::PortfolioImportError
    raise
  rescue ArgumentError, TypeError, Date::Error, RangeError
    invalid_data!
  end

  def inspect
    "#<#{self.class.name} [REDACTED]>"
  end

  alias to_s inspect

  private

    def normalize_row(row)
      invalid_data! unless row.is_a?(Hash)

      sign = value(row, "sign").to_s.strip.upcase
      unsupported_activity! unless SIGNS.include?(sign)

      type = value(row, "type").to_s.strip.upcase
      invalid_data! if type.blank? || type.bytesize > 64

      isin = value(row, "isin").to_s.strip.upcase
      invalid_data! unless isin.match?(ISIN_PATTERN) && FinecoItem::PortfolioNormalizer.valid_isin?(isin)

      transaction_date, transaction_timestamp = bank_timestamp(value(row, "transactionDate"))
      value_date, value_timestamp = bank_timestamp(value(row, "valueDate"))
      quantity = decimal(value(row, "amount"))
      quote_price = decimal(value(row, "price"))
      exchange = decimal(value(row, "exchange"))
      gross_eur = decimal(value(row, "equivalentValue"))
      quote_currency = value(row, "currency").to_s.strip.upcase

      invalid_data! unless quantity.positive? && quote_price >= 0 && exchange.positive? && gross_eur.positive?
      invalid_data! unless quote_currency.match?(/\A[A-Z]{3}\z/)

      description = value(row, "name").presence || value(row, "description").presence || isin

      {
        date: transaction_date,
        transaction_timestamp: transaction_timestamp,
        value_date: value_date,
        value_timestamp: value_timestamp,
        isin: isin,
        name: description.to_s.truncate(200),
        sign: sign,
        type: type,
        quantity: quantity,
        quote_price: quote_price,
        quote_currency: quote_currency,
        exchange: exchange,
        gross_eur: gross_eur
      }
    end

    def value(row, key)
      return row[key] if row.key?(key)
      return row[key.to_sym] if row.key?(key.to_sym)

      nil
    end

    def bank_timestamp(value)
      zone = Time.find_zone!(BANK_TIME_ZONE)

      if value.is_a?(DateTime)
        local_time = value.to_time.in_time_zone(zone)
      elsif value.is_a?(Time)
        local_time = value.in_time_zone(zone)
      elsif value.is_a?(Date)
        local_time = zone.local(value.year, value.month, value.day)
      elsif value.is_a?(String) && value.match?(ISO_DATE_PATTERN)
        date = Date.iso8601(value)
        invalid_data! unless date.iso8601 == value
        local_time = zone.local(date.year, date.month, date.day)
      elsif value.is_a?(String) && (match = ISO_LOCAL_TIMESTAMP_PATTERN.match(value))
        year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
        date = Date.new(year, month, day)
        fraction = match[7].to_s
        invalid_data! if fraction.length > 6
        invalid_data! unless hour.between?(0, 23) && minute.between?(0, 59) && second.between?(0, 59)
        microseconds = fraction.ljust(6, "0").to_i
        local_time = zone.local(date.year, date.month, date.day, hour, minute, second, microseconds)
        invalid_data! unless [ year, month, day, hour, minute, second ] ==
          [ local_time.year, local_time.month, local_time.day, local_time.hour, local_time.min, local_time.sec ]
      elsif value.is_a?(String) && (match = ISO_TIMESTAMP_PATTERN.match(value))
        year, month, day, hour, minute, second = timestamp_components(match)
        Date.new(year, month, day)
        invalid_data! unless hour.between?(0, 23) && minute.between?(0, 59) && second.between?(0, 59)
        invalid_data! if match[:fraction].to_s.length > 7
        validate_offset!(match[:offset])
        local_time = Time.iso8601(value).in_time_zone(zone)
      else
        invalid_data!
      end

      [ local_time.to_date, local_time.iso8601(6) ]
    end

    def timestamp_components(match)
      %i[year month day hour minute second].map { |component| match[component].to_i }
    end

    def validate_offset!(offset)
      return if offset == "Z"

      hours, minutes = offset[1..].split(":").map(&:to_i)
      invalid_data! unless hours.between?(0, 23) && minutes.between?(0, 59)
    end

    def decimal(value)
      parsed = case value
      when BigDecimal then value
      when Integer, Float then BigDecimal(value.to_s)
      when String then BigDecimal(value.strip)
      else
        invalid_data!
      end
      invalid_data! unless parsed.finite?

      parsed
    end

    def signed(value, sign)
      sign == "A" ? value : -value
    end

    def fingerprint_for(draft)
      canonical = [
        1,
        @bank_scope,
        draft.fetch(:transaction_timestamp),
        draft.fetch(:value_timestamp),
        draft.fetch(:isin),
        draft.fetch(:type),
        draft.fetch(:sign),
        decimal_string(draft.fetch(:quantity)),
        decimal_string(draft.fetch(:quote_price)),
        decimal_string(draft.fetch(:exchange)),
        decimal_string(draft.fetch(:gross_eur)),
        draft.fetch(:quote_currency)
      ]
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    def external_id_for(date, fingerprint, occurrence)
      canonical = [ @bank_scope, date.iso8601, fingerprint, occurrence ]
      "#{EXTERNAL_ID_PREFIX}#{Digest::SHA256.hexdigest(JSON.generate(canonical))}"
    end

    def metadata_for(draft, fingerprint, occurrence)
      {
        "history_schema_version" => 1,
        "fingerprint" => fingerprint,
        "occurrence" => occurrence,
        "type" => draft.fetch(:type),
        "sign" => draft.fetch(:sign),
        "transaction_timestamp" => draft.fetch(:transaction_timestamp),
        "original_price" => decimal_string(draft.fetch(:quote_price)),
        "original_currency" => draft.fetch(:quote_currency),
        "exchange" => decimal_string(draft.fetch(:exchange)),
        "value_date" => draft.fetch(:value_date).iso8601
      }
    end

    def cohorts_for(activities)
      cohorts = Hash.new { |days, day| days[day] = Hash.new(0) }
      activities.each do |activity|
        cohorts[activity.date.iso8601][activity.fingerprint] += 1
      end
      cohorts.transform_values { |fingerprints| fingerprints.to_h.freeze }.freeze
    end

    def decimal_string(value)
      value.zero? ? "0" : value.to_s("F")
    end

    def invalid_data!
      raise FinecoItem::PortfolioImportError.new(:history_invalid_data)
    end

    def unsupported_activity!
      raise FinecoItem::PortfolioImportError.new(:history_unsupported_activity)
    end
end
