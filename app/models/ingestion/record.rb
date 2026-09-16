require_relative "../ingestion"
require "bigdecimal"
require "date"

# Normalized financial values, independent of persistence. IDs are the exact
# ingestion IDs, including any legacy prefixes. Source-specific attributes live in
# metadata; unnormalized responses belong in the encrypted batch store.
class Ingestion::Record
  REQUIRED = {
    "account" => %i[external_id name],
    "transaction" => %i[external_id name currency date amount pending],
    "holding" => %i[external_id currency date quantity security],
    "activity" => %i[external_id name currency date amount activity_type]
  }.transform_values(&:freeze).freeze
  OPTIONAL = {
    "account" => %i[currency account_type balance available_balance cash_balance reserved_balance balance_date sensitive_details],
    "transaction" => %i[pending_external_id],
    "holding" => %i[price amount],
    "activity" => %i[quantity price security ledger_type]
  }.transform_values(&:freeze).freeze
  DECIMALS = %i[amount balance available_balance cash_balance reserved_balance quantity price].freeze

  attr_reader :kind, :attributes

  REQUIRED.each_key do |kind|
    define_singleton_method(kind) { |**attributes| new(kind: kind, attributes: attributes) }
  end

  def initialize(kind:, attributes:)
    raise ArgumentError, "unknown record kind" unless REQUIRED.key?(kind)
    raise ArgumentError, "attributes must be a hash" unless attributes.is_a?(Hash)
    missing = REQUIRED.fetch(kind).reject { |key| attributes.key?(key) && !attributes[key].nil? }
    raise ArgumentError, "missing #{missing.join(', ')}" if missing.any?
    unknown = attributes.keys - REQUIRED.fetch(kind) - OPTIONAL.fetch(kind) - [ :metadata ]
    raise ArgumentError, "unknown attributes: #{unknown.join(', ')}" if unknown.any?

    %i[external_id name currency activity_type pending_external_id].each do |key|
      next unless attributes.key?(key) && !attributes[key].nil?
      unless attributes[key].is_a?(String) && !attributes[key].strip.empty?
        raise ArgumentError, "#{key} must be a nonempty string"
      end
    end
    DECIMALS.each do |key|
      next if attributes[key].nil?
      unless attributes[key].is_a?(BigDecimal) && attributes[key].finite?
        raise ArgumentError, "#{key} must be a finite BigDecimal"
      end
    end
    if kind == "account" && attributes[:currency].nil? &&
        %i[balance available_balance cash_balance reserved_balance].any? { |key| !attributes[key].nil? }
      raise ArgumentError, "reported balances require a currency"
    end
    %i[date balance_date].each do |key|
      if attributes.key?(key) && !attributes[key].nil? && !attributes[key].instance_of?(Date)
        raise ArgumentError, "#{key} must be a Date (normalize provider time zones first)"
      end
    end
    if kind == "transaction" && ![ true, false ].include?(attributes[:pending])
      raise ArgumentError, "pending must be boolean"
    end
    if attributes.key?(:ledger_type) && !%w[trade transaction].include?(attributes[:ledger_type])
      raise ArgumentError, "ledger_type must be trade or transaction"
    end
    %i[metadata security sensitive_details].each do |key|
      if attributes.key?(key) && !attributes[key].is_a?(Hash)
        raise ArgumentError, "#{key} must be a hash"
      end
    end

    @kind = kind.dup.freeze
    @attributes = copy_value(attributes)
    freeze
  end

  def [](key)
    attributes[key]
  end

  def ledger_type
    return unless kind == "activity"
    attributes[:ledger_type] || (%w[buy sell].include?(attributes[:activity_type]) ? "trade" : "transaction")
  end

  def inspect
    "#<#{self.class.name} kind=#{kind}>"
  end

  private
    def copy_value(value)
      case value
      when Hash
        value.to_h { |key, item| [ copy_value(key), copy_value(item) ] }.freeze
      when Array
        value.map { |item| copy_value(item) }.freeze
      when String, Date
        value.dup.freeze
      when BigDecimal, Integer, TrueClass, FalseClass, NilClass, Symbol
        value
      when Float
        raise ArgumentError, "metadata numbers must be finite" unless value.finite?
        value
      else
        raise ArgumentError, "record values must be decimals, dates or JSON-compatible data"
      end
    end
end
