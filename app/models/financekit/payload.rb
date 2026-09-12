class Financekit::Payload
  STATUSES = %w[authorized pending booked rejected memo].freeze
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  DECIMAL = /\A(?:0|[1-9][0-9]{0,14})(?:\.[0-9]{1,4})?\z/

  class << self
    def uuid!(value)
      Financekit.require!(value.is_a?(String) && UUID.match?(value))
      value
    end

    def timestamp!(value)
      Financekit.require!(value.is_a?(String) && /(?:Z|[+-]\d{2}:\d{2})\z/.match?(value))
      Time.iso8601(value)
    rescue ArgumentError
      raise Financekit::Error.new("invalid_timestamp")
    end

    def money!(record)
      shape!(record, %w[amount currency credit_debit])
      Financekit.require!(record["amount"].is_a?(String) && DECIMAL.match?(record["amount"]))
      Financekit.require!(record["currency"].is_a?(String) && Money::Currency.new(record["currency"]).iso_code == record["currency"])
      Financekit.require!(%w[credit debit].include?(record["credit_debit"]))
      BigDecimal(record["amount"])
    rescue Money::Currency::UnknownCurrencyError
      raise Financekit::Error.new("invalid_currency")
    end

    def shape!(record, required, optional = [])
      Financekit.require!(record.is_a?(Hash) && (required - record.keys).empty? &&
        (record.keys - required - optional).empty?)
    end

    def text!(value, limit = 255)
      Financekit.require!(value.is_a?(String) && value.present? && value.length <= limit)
    end

    def validate!(data, item)
      shape!(data, %w[captured_at history accounts transactions tombstones])
      capture = timestamp!(data["captured_at"])
      Financekit.require!(capture <= Time.current + 5.minutes, "future_capture")
      history = data["history"]
      shape!(history, %w[kind start_at end_at snapshot_id complete])
      Financekit.require!(%w[delta snapshot].include?(history["kind"]) && [ true, false ].include?(history["complete"]))
      uuid!(history["snapshot_id"])
      Financekit.require!(timestamp!(history["start_at"]) <= timestamp!(history["end_at"]) && timestamp!(history["end_at"]) <= capture)
      %w[accounts transactions tombstones].each { |key| Financekit.require!(data[key].is_a?(Array)) }
      Financekit.require!(data["accounts"].size <= Financekit::MAX_ACCOUNTS &&
        data.values_at("transactions", "tombstones").sum(&:size) <= Financekit::MAX_RECORDS, "record_limit", 413)
      mappings = item.selected_accounts.index_by(&:source_id)
      seen = []
      data["accounts"].each do |record|
        shape!(record, %w[source_id mapping_version observed_at], %w[booked_balance available_balance])
        mapping!(record, mappings)
        Financekit.require!(!seen.include?(record["source_id"]))
        seen << record["source_id"]
        Financekit.require!(timestamp!(record["observed_at"]) <= capture)
        %w[booked_balance available_balance].each do |key|
          next unless record.key?(key)
          money!(record[key])
          Financekit.require!(record[key]["currency"] == mappings.fetch(record["source_id"]).currency)
        end
      end
      seen = []
      data["transactions"].each do |record|
        shape!(record, %w[source_id account_id mapping_version amount currency credit_debit transacted_at status type], %w[posted_at merchant description])
        transaction_identity!(record, mappings, seen)
        money!(record.slice("amount", "currency", "credit_debit"))
        Financekit.require!(record["currency"] == mappings.fetch(record["account_id"]).currency, "currency_mismatch")
        Financekit.require!(STATUSES.include?(record["status"]))
        text!(record["type"], 100)
        text!(record["merchant"]) if record.key?("merchant")
        text!(record["description"], 1000) if record.key?("description")
        Financekit.require!(timestamp!(record["transacted_at"]) <= capture)
        Financekit.require!(record.key?("posted_at")) if record["status"] == "booked"
        Financekit.require!(timestamp!(record["posted_at"]) <= capture) if record.key?("posted_at")
      end
      data["tombstones"].each do |record|
        shape!(record, %w[source_id account_id mapping_version])
        transaction_identity!(record, mappings, seen)
      end
      data
    end

    def mapping!(record, mappings, key = "source_id")
      uuid!(record[key])
      mapping = mappings[record[key]]
      Financekit.require!(mapping && record["mapping_version"].is_a?(Integer) && mapping.mapping_version == record["mapping_version"] && mapping.account,
        "mapping_conflict", 409)
    end

    def transaction_identity!(record, mappings, seen)
      mapping!(record, mappings, "account_id")
      uuid!(record["source_id"])
      identity = record.values_at("account_id", "source_id")
      Financekit.require!(!seen.include?(identity), "duplicate_record")
      seen << identity
    end
  end
end
