# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

class Provider::BankBalanceSnapshot
  INVALID_SNAPSHOT_MESSAGE = "Invalid bank balance snapshot".freeze
  SOURCE_TYPE_LIMIT = 128
  MISSING_BALANCES = Object.new.freeze

  BALANCE_TYPES = {
    "clbd" => [ :booked, 0 ],
    "closingbooked" => [ :booked, 0 ],
    "itbd" => [ :booked, 1 ],
    "interimbooked" => [ :booked, 1 ],
    "opbd" => [ :booked, 2 ],
    "openingbooked" => [ :booked, 2 ],
    "prcd" => [ :booked, 3 ],
    "previouslyclosedbooked" => [ :booked, 3 ],
    "itav" => [ :available, 0 ],
    "interimavailable" => [ :available, 0 ],
    "clav" => [ :available, 1 ],
    "closingavailable" => [ :available, 1 ],
    "opav" => [ :available, 2 ],
    "openingavailable" => [ :available, 2 ],
    "xpcd" => [ :expected, 0 ],
    "expected" => [ :expected, 0 ]
  }.freeze

  BALANCE_KINDS = %i[booked available expected].freeze

  class InvalidSnapshot < StandardError
    def initialize(_message = nil)
      super(Provider::BankBalanceSnapshot::INVALID_SNAPSHOT_MESSAGE)
    end
  end

  class Observation
    attr_reader :money, :source_type, :reference_date, :last_changed_at

    def initialize(money:, source_type:, reference_date: nil, last_changed_at: nil, mapped_from_expected: false)
      @money = money
      @source_type = source_type
      @reference_date = reference_date
      @last_changed_at = last_changed_at
      @mapped_from_expected = mapped_from_expected == true
      freeze
    end

    def mapped_from_expected?
      @mapped_from_expected
    end

    def with_mapped_from_expected
      self.class.new(
        money: money,
        source_type: source_type,
        reference_date: reference_date,
        last_changed_at: last_changed_at,
        mapped_from_expected: true
      )
    end

    def to_payload
      {
        "amount" => money.amount.to_s("F"),
        "currency" => money.currency.iso_code,
        "source_type" => source_type,
        "reference_date" => reference_date&.iso8601,
        "last_changed_at" => last_changed_at&.iso8601(6),
        "mapped_from_expected" => mapped_from_expected?
      }
    end

    def self.from_enable_banking(balance, source_type:)
      amount, currency = source_values(balance)
      decimal = decimal_amount(amount)
      currency_object = currency_object(currency)
      indicator = value_at(balance, "credit_debit_indicator")

      signed_amount = case indicator
      when nil
        decimal
      when String
        case indicator.strip.upcase
        when "CRDT"
          decimal
        when "DBIT"
          -decimal.abs
        else
          raise InvalidSnapshot
        end
      else
        raise InvalidSnapshot
      end

      new(
        money: Money.new(signed_amount, currency_object),
        source_type: source_type.to_s.first(SOURCE_TYPE_LIMIT),
        reference_date: strict_date(value_at(balance, "reference_date")),
        last_changed_at: optional_time(value_at(balance, "last_change_date_time"))
      )
    rescue InvalidSnapshot
      raise
    rescue StandardError
      raise InvalidSnapshot
    end

    def self.from_payload(payload)
      return unless payload.is_a?(Hash)

      amount = value_at(payload, "amount")
      currency = value_at(payload, "currency")
      raw_source_type = value_at(payload, "source_type")
      return unless raw_source_type.is_a?(String) && !raw_source_type.empty?

      new(
        money: Money.new(decimal_amount(amount), currency_object(currency)),
        source_type: raw_source_type.first(SOURCE_TYPE_LIMIT),
        reference_date: strict_date(value_at(payload, "reference_date")),
        last_changed_at: optional_time(value_at(payload, "last_changed_at")),
        mapped_from_expected: value_at(payload, "mapped_from_expected") == true
      )
    rescue StandardError
      nil
    end

    def self.source_values(balance)
      nested = value_at(balance, "balance_amount")

      if nested.nil?
        [ value_at(balance, "amount"), value_at(balance, "currency") ]
      elsif nested.is_a?(Hash)
        amount = value_at(nested, "amount")
        currency = value_at(nested, "currency")
        amount = value_at(balance, "amount") if amount.nil?
        currency = value_at(balance, "currency") if currency.nil?
        [ amount, currency ]
      else
        raise InvalidSnapshot
      end
    end

    def self.decimal_amount(value)
      raise InvalidSnapshot unless value.is_a?(String) || value.is_a?(Numeric)

      amount = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
      raise InvalidSnapshot unless amount.finite?

      amount
    rescue InvalidSnapshot
      raise
    rescue StandardError
      raise InvalidSnapshot
    end

    def self.currency_object(value)
      raise InvalidSnapshot unless value.is_a?(String) && value.strip.match?(/\A[A-Za-z]{3}\z/)

      Money::Currency.new(value.strip)
    rescue InvalidSnapshot
      raise
    rescue StandardError
      raise InvalidSnapshot
    end

    def self.strict_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(value)
    rescue StandardError
      nil
    end

    def self.optional_time(value)
      case value
      when Time
        value
      when DateTime
        value.to_time
      when String
        return unless value.match?(/T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/i)

        Time.iso8601(value)
      else
        value.to_time if value.respond_to?(:to_time) && value.respond_to?(:utc_offset)
      end
    rescue StandardError
      nil
    end

    def self.value_at(hash, key)
      return unless hash.is_a?(Hash)
      return hash[key] if hash.key?(key)

      hash[key.to_sym] if hash.key?(key.to_sym)
    end

    private_class_method :source_values, :decimal_amount, :currency_object, :strict_date
  end

  attr_reader :fetched_at, :last_attempted_at

  def self.build_enable_banking(balances: MISSING_BALANCES, fetched_at:, bank_name:, country_code:, currency: nil)
    raise InvalidSnapshot unless balances.is_a?(Array) && timestamp_input?(fetched_at)

    candidates = Hash.new { |hash, kind| hash[kind] = [] }
    has_actual_available = false

    balances.each_with_index do |balance, index|
      raise InvalidSnapshot unless balance.is_a?(Hash)

      raw_type = value_at(balance, "balance_type")
      next unless raw_type.is_a?(String) || raw_type.is_a?(Symbol)

      source_type = raw_type.to_s
      descriptor = BALANCE_TYPES[normalize_type(source_type)]
      next unless descriptor

      kind, priority = descriptor
      observation = Observation.from_enable_banking(balance, source_type: source_type)
      next if currency && observation.money.currency.iso_code != currency

      candidates[kind] << [ priority, index, observation ]
      has_actual_available ||= kind == :available
    end

    observations = BALANCE_KINDS.to_h do |kind|
      selected = candidates[kind].min_by { |priority, index, _observation| [ priority, index ] }
      [ kind, selected&.last ]
    end

    if bper_banca?(bank_name, country_code) && !has_actual_available && observations[:expected]
      observations[:available] = observations[:expected].with_mapped_from_expected
      observations[:expected] = nil
    end

    fetched_at_string = timestamp_input(fetched_at)
    {
      "fetched_at" => fetched_at_string,
      "last_attempted_at" => fetched_at_string,
      "status" => "complete",
      "balances" => BALANCE_KINDS.to_h do |kind|
        [ kind.to_s, observations[kind]&.to_payload ]
      end
    }
  rescue InvalidSnapshot
    raise
  rescue StandardError
    raise InvalidSnapshot
  end

  def initialize(payload)
    payload = {} unless payload.is_a?(Hash)

    @fetched_at = Observation.optional_time(Observation.value_at(payload, "fetched_at"))
    @last_attempted_at = Observation.optional_time(Observation.value_at(payload, "last_attempted_at"))
    @failed = Observation.value_at(payload, "status").to_s == "failed"

    raw_balances = Observation.value_at(payload, "balances")
    raw_balances = {} unless raw_balances.is_a?(Hash)
    @observations = BALANCE_KINDS.to_h do |kind|
      [ kind, Observation.from_payload(Observation.value_at(raw_balances, kind.to_s)) ]
    end.freeze
  rescue StandardError
    @fetched_at = nil
    @last_attempted_at = nil
    @failed = false
    @observations = {}.freeze
  end

  def failed?
    @failed
  end

  def booked
    @observations[:booked]
  end

  def available
    @observations[:available]
  end

  def expected
    @observations[:expected]
  end

  def self.normalize_type(type)
    type.gsub(/[_-]/, "").downcase
  end

  def self.bper_banca?(bank_name, country_code)
    bank_name.is_a?(String) && bank_name.strip.casecmp?("BPER Banca") &&
      country_code.is_a?(String) && country_code.upcase == "IT"
  end

  def self.timestamp_input?(value)
    value.is_a?(Time) ||
      (value.respond_to?(:iso8601) && value.respond_to?(:utc_offset) && value.respond_to?(:to_time))
  end

  def self.timestamp_input(value)
    raise InvalidSnapshot unless timestamp_input?(value)

    value.to_time.iso8601(6)
  rescue InvalidSnapshot
    raise
  rescue StandardError
    raise InvalidSnapshot
  end

  def self.value_at(hash, key)
    Observation.value_at(hash, key)
  end

  private_class_method :normalize_type, :bper_banca?, :timestamp_input?, :timestamp_input, :value_at
end
