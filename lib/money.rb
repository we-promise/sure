class Money
  include Comparable, Arithmetic, Formatting
  include ActiveModel::Validations

  class ConversionError < StandardError
    attr_reader :from_currency, :to_currency, :date

    def initialize(from_currency:, to_currency:, date:)
      @from_currency = from_currency
      @to_currency = to_currency
      @date = date

      super("Couldn't find exchange rate from #{from_currency} to #{to_currency} on #{date}")
    end
  end

  # Raised (strict mode) or reported (otherwise) when an operation combines
  # two amounts in different currencies. The operators can't convert: they
  # don't know which date the rate is for, and that differs per caller (trade
  # date, price date, today). Callers convert with `exchange_to` first.
  class CurrencyMismatchError < StandardError
    attr_reader :left_currency, :right_currency, :operation

    def initialize(left_currency:, right_currency:, operation:)
      @left_currency = left_currency
      @right_currency = right_currency
      @operation = operation

      super("Can't apply #{operation} to #{left_currency} and #{right_currency} amounts; convert one with exchange_to first")
    end
  end

  REPORTED_MISMATCHES_LIMIT = 500

  attr_reader :amount, :currency, :store

  validate :source_must_be_of_known_type

  class << self
    def default_currency
      @default ||= Money::Currency.new(:usd)
    end

    def default_currency=(object)
      @default = Money::Currency.new(object)
    end

    # On in development and test (config/initializers/money.rb): mixing
    # currencies raises. Off in production: the mismatch is reported and the
    # operation keeps its legacy result, so a page that shows a wrong figure
    # today doesn't start failing.
    attr_writer :strict_currency

    def strict_currency?
      @strict_currency == true
    end

    # Once the memory is full it starts over instead of going quiet, so a
    # long-running process still reports new call sites (known ones may be
    # reported once more).
    def first_mismatch_report?(key)
      @reported_mismatches ||= Concurrent::Set.new
      @reported_mismatches.clear if @reported_mismatches.size >= REPORTED_MISMATCHES_LIMIT

      !@reported_mismatches.add?(key).nil?
    end

    def reset_reported_mismatches!
      @reported_mismatches = nil
    end
  end

  def initialize(obj, currency = Money.default_currency, store: ExchangeRate)
    @source = obj
    @amount = obj.is_a?(Money) ? obj.amount : BigDecimal(obj.to_s)
    @currency = obj.is_a?(Money) ? obj.currency : Money::Currency.new(currency)
    @store = store

    validate!
  end

  # Exchange money to another currency
  # Params:
  #   other_currency: target currency code (e.g. "USD")
  #   date: date for historical rates (default: Date.current)
  #   custom_rate: explicit exchange rate to use (skips lookup if provided, including nil check)
  # Priority:
  #   1. Use custom_rate if explicitly provided (not nil)
  #   2. Look up rate via store.find_or_fetch_rate
  #   3. Raise ConversionError if no valid rate available
  def exchange_to(other_currency, date: Date.current, custom_rate: nil)
    iso_code = currency.iso_code
    other_iso_code = Money::Currency.new(other_currency).iso_code

    if iso_code == other_iso_code
      self
    else
      # Use custom rate if provided, otherwise look it up
      if custom_rate.present?
        exchange_rate = custom_rate.to_d
      else
        exchange_rate = store.find_or_fetch_rate(from: iso_code, to: other_iso_code, date: date)&.rate
      end

      raise ConversionError.new(from_currency: iso_code, to_currency: other_iso_code, date: date) unless exchange_rate && exchange_rate > 0

      Money.new(amount * exchange_rate, other_iso_code)
    end
  end

  # Rounded to the precision `format` actually prints.
  def for_display
    self.class.new(amount.round(currency.default_precision), currency)
  end

  def as_json
    { amount: amount, currency: currency.iso_code, formatted: format }.as_json
  end

  # Amounts in different currencies are simply not equal; only ordering them
  # (<, >, <=>) needs a conversion.
  def ==(other)
    return false if other.is_a?(Money) && currency != other.currency

    super
  end

  def <=>(other)
    raise TypeError, "Money can only be compared with other Money objects except for 0" unless other.is_a?(Money) || other.eql?(0)

    if other.is_a?(Numeric)
      amount <=> other
    else
      ensure_same_currency!(other, :<=>)
      amount_comparison = amount <=> other.amount

      if amount_comparison == 0
        currency <=> other.currency
      else
        amount_comparison
      end
    end
  end

  private
    def ensure_same_currency!(other, operation)
      return if currency == other.currency

      error = CurrencyMismatchError.new(left_currency: currency.iso_code, right_currency: other.currency.iso_code, operation: operation)
      raise error if self.class.strict_currency?

      # Once per call site and process: a sort or a long sync would otherwise
      # report the same mismatch thousands of times.
      call_site = caller_locations(2, 1).first&.to_s
      return unless self.class.first_mismatch_report?([ operation, error.left_currency, error.right_currency, call_site ])

      Rails.error.report(error, handled: true, severity: :warning, source: "money", context: { call_site: call_site })
      Rails.logger.warn("[Money] #{error.message} (#{call_site})")
    end

    def source_must_be_of_known_type
      unless @source.is_a?(Money) || @source.is_a?(Numeric) || @source.is_a?(BigDecimal)
        errors.add :source, "must be a Money, Numeric, or BigDecimal"
      end
    end
end
