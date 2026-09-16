require "bigdecimal"
require "date"
require "json"
require "time"

# Legacy rows contain timestamps and decimals that plain JSON cannot round-trip.
# Tags are outside values, so provider-supplied keys cannot impersonate a type.
class Provider::AccountData::MigrationValue
  def self.dump(value)
    JSON.generate(encode(value))
  end

  def self.load(serialized)
    decode(JSON.parse(serialized))
  end

  def self.encode(value)
    if defined?(ActiveSupport::TimeWithZone) && value.is_a?(ActiveSupport::TimeWithZone)
      return [ "time", value.iso8601(9) ]
    end

    case value
    when Hash
      pairs = value.map { |key, item| [ encode(key), encode(item) ] }
      [ "hash", pairs.sort_by { |pair| JSON.generate(pair.first) } ]
    when Array then [ "array", value.map { |item| encode(item) } ]
    when BigDecimal
      raise ArgumentError, "Nonfinite migration decimal" unless value.finite?
      [ "decimal", value.to_s("F") ]
    when DateTime then [ "datetime", value.iso8601(9) ]
    when Date then [ "date", value.iso8601 ]
    when Time then [ "time", value.iso8601(9) ]
    when Symbol then [ "symbol", value.to_s ]
    when Float
      raise ArgumentError, "Nonfinite migration number" unless value.finite?
      [ "scalar", value ]
    when String, Integer, TrueClass, FalseClass, NilClass then [ "scalar", value ]
    else raise ArgumentError, "Unsupported migration value type"
    end
  end

  def self.decode(encoded)
    raise ArgumentError, "Invalid migration value" unless encoded.is_a?(Array) && encoded.size == 2

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
      result = BigDecimal(value)
      raise ArgumentError unless result.finite?
      result
    when "date" then Date.iso8601(value)
    when "datetime" then DateTime.iso8601(value)
    when "time" then Time.iso8601(value)
    when "symbol"
      raise ArgumentError unless value.is_a?(String)
      value.to_sym
    when "scalar"
      unless value.nil? || value.is_a?(String) || value.is_a?(Integer) || value == true || value == false ||
          (value.is_a?(Float) && value.finite?)
        raise ArgumentError
      end
      value
    else raise ArgumentError, "Unknown migration value tag"
    end
  end
end
