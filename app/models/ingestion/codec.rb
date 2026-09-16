require "bigdecimal"
require "date"

# A versioned, lossless wire format for captured canonical pages. Type tags wrap
# values rather than being mixed into source metadata, so arbitrary source keys
# cannot impersonate a serialized decimal/date.
class Ingestion::Codec
  VERSION = 1
  PAYLOAD_KEYS = %w[version records complete mode next_cursor checkpoint_cursor removed_ids coverage warnings].freeze

  def self.dump(page)
    raise ArgumentError, "Expected a canonical ingestion page" unless page.is_a?(Provider::AccountData::Page)

    {
      "version" => VERSION,
      "records" => page.records.map { |record| { "kind" => record.kind, "attributes" => encode(record.attributes) } },
      "complete" => page.complete?, "mode" => page.mode,
      "next_cursor" => page.next_cursor, "checkpoint_cursor" => page.checkpoint_cursor,
      "progress_cursor" => page.progress_cursor,
      "removed_ids" => page.removed_ids, "coverage" => encode(page.coverage), "warnings" => encode(page.warnings),
      "evidence" => encode(page.evidence)
    }
  end

  def self.load(payload)
    raise ArgumentError, "Invalid ingestion payload" unless payload.is_a?(Hash)
    unless payload["version"].instance_of?(Integer) && payload["version"] == VERSION
      raise ArgumentError, "Unsupported ingestion payload version"
    end

    load_page(payload)
  end

  def self.load_page(payload)
    # Optional evidence/progress were added after the first captured batches. Those
    # batches remain replayable; all other unknown or missing keys still fail.
    raise ArgumentError unless (payload.keys - %w[evidence progress_cursor]).sort == PAYLOAD_KEYS.sort && payload["records"].is_a?(Array)

    records = payload.fetch("records").map do |record|
      raise ArgumentError unless record.is_a?(Hash) && record.keys.sort == %w[attributes kind]

      Ingestion::Record.new(kind: record.fetch("kind"), attributes: decode(record.fetch("attributes")))
    end
    Provider::AccountData::Page.new(
      records: records, complete: payload.fetch("complete"), mode: payload.fetch("mode"),
      next_cursor: payload.fetch("next_cursor"), checkpoint_cursor: payload.fetch("checkpoint_cursor"),
      progress_cursor: payload["progress_cursor"],
      removed_ids: payload.fetch("removed_ids"), coverage: decode(payload.fetch("coverage")),
      warnings: decode(payload.fetch("warnings")), evidence: payload.key?("evidence") ? decode(payload.fetch("evidence")) : {}
    )
  rescue KeyError, TypeError, NoMethodError, ArgumentError
    raise ArgumentError, "Invalid ingestion payload", cause: nil
  end
  private_class_method :load_page

  def self.encode(value)
    case value
    when Hash then [ "hash", value.map { |key, item| [ encode(key), encode(item) ] } ]
    when Array then [ "array", value.map { |item| encode(item) } ]
    when BigDecimal
      raise ArgumentError, "Nonfinite ingestion decimal" unless value.finite?
      [ "decimal", value.to_s("F") ]
    when DateTime
      raise ArgumentError, "Normalize ingestion timestamps before encoding"
    when Date then [ "date", value.iso8601 ]
    when Symbol then [ "symbol", value.to_s ]
    when Float
      raise ArgumentError, "Nonfinite ingestion number" unless value.finite?
      [ "scalar", value ]
    when String, Integer, TrueClass, FalseClass, NilClass then [ "scalar", value ]
    else raise ArgumentError, "Unsupported ingestion value"
    end
  end
  private_class_method :encode

  def self.decode(encoded)
    raise ArgumentError unless encoded.is_a?(Array) && encoded.size == 2

    type, value = encoded
    case type
    when "hash"
      raise ArgumentError unless value.is_a?(Array)
      value.each_with_object({}) do |pair, result|
        raise ArgumentError unless pair.is_a?(Array) && pair.size == 2
        key = decode(pair.first)
        raise ArgumentError if result.key?(key)
        result[key] = decode(pair.last)
      end
    when "array"
      raise ArgumentError unless value.is_a?(Array)
      value.map { |item| decode(item) }
    when "decimal"
      raise ArgumentError unless value.is_a?(String)
      decimal = BigDecimal(value)
      raise ArgumentError unless decimal.finite?
      decimal
    when "date"
      raise ArgumentError unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      Date.iso8601(value)
    when "symbol"
      raise ArgumentError unless value.is_a?(String)
      value.to_sym
    when "scalar"
      unless value.nil? || value.is_a?(String) || value.instance_of?(Integer) ||
          value.instance_of?(TrueClass) || value.instance_of?(FalseClass) ||
          (value.instance_of?(Float) && value.finite?)
        raise ArgumentError
      end
      value
    else raise ArgumentError
    end
  end
  private_class_method :decode
end
