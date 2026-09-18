class Financekit::Payload
  STATUSES = %w[authorized pending booked rejected memo].freeze
  EVENT_KINDS = %w[account_upsert account_unavailable balance_upsert transaction_upsert transaction_tombstone].freeze
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  DIGEST = /\A[0-9a-f]{64}\z/
  DECIMAL = /\A(?:0|[1-9][0-9]{0,14})(?:\.[0-9]{1,4})?\z/
  EXCHANGE_RATE = /\A(?:0|[1-9][0-9]{0,17})(?:\.[0-9]{1,18})?\z/

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
      shape!(record, %w[amount currency direction])
      Financekit.require!(record["amount"].is_a?(String) && DECIMAL.match?(record["amount"]))
      Financekit.require!(record["currency"].is_a?(String) && Money::Currency.new(record["currency"]).iso_code == record["currency"])
      Financekit.require!(%w[credit debit].include?(record["direction"]))
      BigDecimal(record["amount"])
    rescue Money::Currency::UnknownCurrencyError
      raise Financekit::Error.new("invalid_currency")
    end

    def shape!(record, required, optional = [])
      Financekit.require!(record.is_a?(Hash) && (required - record.keys).empty? &&
        (record.keys - required - optional).empty?)
    end

    def text!(value, limit = 255, allow_empty: false)
      Financekit.require!(value.is_a?(String) && (allow_empty || value.present?) && value.length <= limit)
    end

    def validate_batch!(data, item)
      shape!(data, %w[protocol_version connection_id publisher_id generation stream_id batch_id sequence capture_id
        chunk_index chunk_count capture_mode snapshot_complete captured_at selected_source_account_ids events],
        %w[predecessor_digest])
      validate_stream!(data, item)
      capture = timestamp!(data["captured_at"])
      Financekit.require!(capture <= Time.current + 5.minutes, "future_capture")
      Financekit.require!(%w[snapshot delta].include?(data["capture_mode"]))
      Financekit.require!([ true, false ].include?(data["snapshot_complete"]))
      Financekit.require!(data["snapshot_complete"] == false || data["capture_mode"] == "snapshot")
      Financekit.require!(data["chunk_index"].is_a?(Integer) && data["chunk_count"].is_a?(Integer) &&
        data["chunk_index"].between?(0, data["chunk_count"] - 1))
      ids = data["selected_source_account_ids"]
      normalized_ids = ids.is_a?(Array) ? ids.map { |id| id.to_s.downcase } : []
      Financekit.require!(ids.is_a?(Array) && normalized_ids.uniq.size == ids.size &&
        normalized_ids.sort == item.consented_source_ids.map(&:downcase).sort, "scope_conflict", 409)
      ids.each { |id| uuid!(id) }
      Financekit.require!(data["events"].is_a?(Array) && data["events"].size <= Financekit::MAX_RECORDS,
        "record_limit", 413)

      mappings = item.selected_accounts.includes(:financekit_account_lineage).index_by { |mapping| mapping.source_id.downcase }
      seen = Set.new
      data["events"].each { |event| validate_event!(event, mappings, seen, capture) }
      data
    end

    private

      def validate_stream!(data, item)
        Financekit.require!(data["protocol_version"] == Financekit::VERSION, "unsupported_protocol", 400)
        %w[connection_id publisher_id stream_id batch_id capture_id].each { |key| uuid!(data[key]) }
        Financekit.require!(data["connection_id"].casecmp?(item.id) && data["publisher_id"].casecmp?(item.publisher_id) &&
          data["stream_id"].casecmp?(item.stream_id), "publisher_conflict", 409)
        Financekit.require!(data["generation"] == item.generation, "generation_conflict", 409)
        Financekit.require!(data["sequence"].is_a?(Integer) && data["sequence"].between?(1, 9_007_199_254_740_991))
        predecessor = data["predecessor_digest"]
        Financekit.require!(predecessor.nil? || (predecessor.is_a?(String) && DIGEST.match?(predecessor)))
        Financekit.require!((data["sequence"] == 1) == predecessor.nil?, "invalid_predecessor")
      end

      def validate_event!(event, mappings, seen, capture)
        Financekit.require!(event.is_a?(Hash) && EVENT_KINDS.include?(event["kind"]))
        case event["kind"]
        when "account_upsert"
          shape!(event, %w[kind account])
          validate_account!(event.fetch("account"), mappings, seen)
        when "account_unavailable"
          shape!(event, %w[kind source_account_id lineage_id mapping_version])
          validate_unavailable!(event, mappings, seen)
        when "balance_upsert"
          shape!(event, %w[kind balance])
          validate_balance!(event.fetch("balance"), mappings, seen, capture)
        when "transaction_upsert"
          shape!(event, %w[kind transaction])
          validate_transaction!(event.fetch("transaction"), mappings, seen, capture)
        when "transaction_tombstone"
          shape!(event, %w[kind tombstone])
          validate_tombstone!(event.fetch("tombstone"), mappings, seen)
        end
      end

      def validate_account!(record, mappings, seen)
        shape!(record, %w[source_id lineage_id mapping_version display_name institution_name currency kind],
          %w[account_description opening_date])
        mapping = mapping!(record, mappings, "source_id")
        Financekit.require!(record["currency"] == mapping.currency, "currency_mismatch")
        expected_kind = mapping.accountable_type == "CreditCard" ? "liability" : "asset"
        Financekit.require!(record["kind"] == expected_kind, "account_type_conflict", 409)
        text!(record["display_name"])
        text!(record["institution_name"])
        text!(record["account_description"], 1000, allow_empty: true) if record.key?("account_description")
        timestamp!(record["opening_date"]) if record.key?("opening_date")
        unique!(seen, [ "account", mapping.id ])
      end

      def validate_unavailable!(event, mappings, seen)
        mapping = mapping!(event, mappings, "source_account_id")
        unique!(seen, [ "account_unavailable", mapping.id ])
      end

      def validate_balance!(record, mappings, seen, capture)
        shape!(record, %w[source_id source_account_id lineage_id mapping_version kind observed_at money])
        uuid!(record["source_id"])
        mapping = mapping!(record, mappings, "source_account_id")
        Financekit.require!(%w[available booked].include?(record["kind"]))
        Financekit.require!(timestamp!(record["observed_at"]) <= capture)
        money!(record["money"])
        Financekit.require!(record["money"]["currency"] == mapping.currency, "currency_mismatch")
        unique!(seen, [ "balance", mapping.financekit_account_lineage_id, record["source_id"].downcase,
          record["kind"], record["observed_at"] ])
      end

      def validate_transaction!(record, mappings, seen, capture)
        shape!(record, %w[source_id source_account_id lineage_id mapping_version amount transaction_description
          original_transaction_description transaction_type status transacted_at],
          %w[foreign_amount foreign_exchange_rate merchant_name merchant_category_code posted_at])
        uuid!(record["source_id"])
        mapping = mapping!(record, mappings, "source_account_id")
        money!(record["amount"])
        Financekit.require!(record["amount"]["currency"] == mapping.currency, "currency_mismatch")
        money!(record["foreign_amount"]) if record.key?("foreign_amount")
        if record.key?("foreign_exchange_rate")
          Financekit.require!(record["foreign_exchange_rate"].is_a?(String) && EXCHANGE_RATE.match?(record["foreign_exchange_rate"]))
        end
        Financekit.require!(STATUSES.include?(record["status"]))
        text!(record["transaction_type"], 100)
        text!(record["transaction_description"], 1000, allow_empty: true)
        text!(record["original_transaction_description"], 1000, allow_empty: true)
        text!(record["merchant_name"]) if record.key?("merchant_name")
        if record.key?("merchant_category_code")
          Financekit.require!(record["merchant_category_code"].is_a?(Integer) && record["merchant_category_code"].between?(-32_768, 32_767))
        end
        Financekit.require!(timestamp!(record["transacted_at"]) <= capture)
        Financekit.require!(record.key?("posted_at")) if record["status"] == "booked"
        Financekit.require!(timestamp!(record["posted_at"]) <= capture) if record.key?("posted_at")
        unique!(seen, [ "transaction", mapping.financekit_account_lineage_id, record["source_id"].downcase ])
      end

      def validate_tombstone!(record, mappings, seen)
        shape!(record, %w[source_id source_account_id lineage_id mapping_version])
        uuid!(record["source_id"])
        mapping = mapping!(record, mappings, "source_account_id")
        unique!(seen, [ "transaction", mapping.financekit_account_lineage_id, record["source_id"].downcase ])
      end

      def mapping!(record, mappings, key)
        uuid!(record[key])
        uuid!(record["lineage_id"])
        mapping = mappings[record[key].downcase]
        Financekit.require!(mapping && record["mapping_version"].is_a?(Integer) &&
          mapping.mapping_version == record["mapping_version"] &&
          mapping.financekit_account_lineage_id.casecmp?(record["lineage_id"]), "mapping_conflict", 409)
        mapping
      end

      def unique!(seen, identity)
        Financekit.require!(!seen.include?(identity), "duplicate_record")
        seen << identity
      end
  end
end
