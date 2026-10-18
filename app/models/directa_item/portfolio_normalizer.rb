class DirectaItem::PortfolioNormalizer
  ACCOUNT_CURRENCY = "EUR".freeze
  ISIN_PATTERN = /\A[A-Z]{2}[A-Z0-9]{9}[0-9]\z/
  MIC_PATTERN = /\A[A-Z0-9]{4}\z/
  MAX_OBSERVATION_AGE = 24.hours
  MAX_FUTURE_SKEW = 5.minutes

  Position = Data.define(
    :isin,
    :mic,
    :name,
    :quantity,
    :market_value,
    :price,
    :cost_basis,
    :external_id,
    :metadata
  )

  Snapshot = Data.define(
    :account_identity,
    :account_number,
    :connection_generation,
    :observed_at,
    :date,
    :currency,
    :cash_balance,
    :current_balance,
    :positions,
    :raw_position_metadata
  )

  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code.to_s
      super(DirectaItem::SYNC_ERROR_MESSAGES.fetch(@code, DirectaItem::SYNC_ERROR_MESSAGES.fetch("sync_failed")))
    end
  end

  def initialize(item)
    @item = item
  end

  def normalize(source)
    validate_source!(source)
    validate_identity!(source)
    validate_cash!(source.cash)

    observed_at = source.observed_at
    date = observed_at.to_date
    positions = normalize_positions(source.positions, date: date)
    cash_balance = source.cash.amount

    Snapshot.new(
      account_identity: source.account_identity,
      account_number: source.account_number,
      connection_generation: source.connection_generation,
      observed_at: observed_at,
      date: date,
      currency: ACCOUNT_CURRENCY,
      cash_balance: cash_balance,
      current_balance: cash_balance + positions.sum(BigDecimal("0"), &:market_value),
      positions: positions,
      raw_position_metadata: positions.any? ? positions.map(&:metadata) : nil
    )
  rescue Error
    raise
  rescue StandardError
    raise Error.new(:invalid_snapshot), cause: nil
  end

  def self.valid_isin?(value)
    isin = value.to_s.upcase
    return false unless isin.match?(ISIN_PATTERN)

    expanded = isin.chars.flat_map do |character|
      character.match?(/[A-Z]/) ? (character.ord - 55).to_s.chars : [ character ]
    end
    checksum = expanded.reverse.each_with_index.sum do |digit, index|
      value = digit.to_i
      value *= 2 if index.odd?
      value -= 9 if value > 9
      value
    end

    (checksum % 10).zero?
  end

  private

    def validate_source!(source)
      unless source.is_a?(Provider::Directa::Snapshot) && source.complete? &&
             source.cash_seen && source.positions_complete && source.observed_at.present?
        raise Error.new(:partial_snapshot)
      end

      if Array(source.unknown_message_types).any?
        raise Error.new(:partial_snapshot)
      end

      if source.observed_at > Time.current + MAX_FUTURE_SKEW || source.observed_at < Time.current - MAX_OBSERVATION_AGE
        raise Error.new(:invalid_snapshot)
      end
    end

    def validate_identity!(source)
      same_account = secure_equal?(source.account_number, @item.broker_account) &&
        secure_equal?(source.account_identity, @item.account_identity)
      same_generation = source.connection_generation == @item.connection_generation
      return if same_account && same_generation

      raise Error.new(:account_identity_changed)
    end

    def validate_cash!(cash)
      return if cash.present? && cash.amount.is_a?(BigDecimal) && cash.amount.finite? &&
        cash.currency == ACCOUNT_CURRENCY && cash.currency_status == :verified &&
        cash.currency_source.present?

      raise Error.new(:awaiting_valuation)
    end

    def normalize_positions(source_positions, date:)
      positions = Array(source_positions)
      external_codes = positions.map { |position| position.univoco&.to_s&.strip }
      raise Error.new(:awaiting_valuation) if external_codes.any?(&:blank?)
      raise Error.new(:duplicate_position) unless external_codes.uniq.length == external_codes.length

      normalized = positions.filter_map { |position| normalize_position(position, date: date) }
      grouped = normalized.group_by { |position| [ position.isin, position.mic ] }
      grouped.map do |identity, rows|
        aggregate_positions(identity, rows)
      end.sort_by { |position| [ position.isin, position.mic ] }
    rescue NoMethodError
      raise Error.new(:awaiting_valuation), cause: nil
    end

    def normalize_position(position, date:)
      metadata = position.instrument_metadata
      quantity = decimal(position.quantity)
      return if quantity.zero? && zero_valued?(position)
      raise Error.new(:invalid_snapshot) unless quantity.positive?

      unless position.identity_status == :verified && metadata.present?
        raise Error.new(:awaiting_valuation)
      end

      isin = metadata.isin.to_s.upcase
      mic = metadata.mic.to_s.upcase
      unless self.class.valid_isin?(isin) && mic.match?(MIC_PATTERN) && Security::EXCHANGES.key?(mic)
        raise Error.new(:awaiting_valuation)
      end

      unless position.valuation_status == :verified && position.valuation_date.is_a?(Date) &&
             position.valuation_date <= date &&
             position.valuation_currency == ACCOUNT_CURRENCY && position.valuation_source.present?
        raise Error.new(:awaiting_valuation)
      end

      market_value = position.market_value
      current_price = position.current_price
      unless market_value.is_a?(BigDecimal) && market_value.finite?
        unless current_price.is_a?(BigDecimal) && current_price.finite? && metadata.currency == ACCOUNT_CURRENCY
          raise Error.new(:awaiting_valuation)
        end
        market_value = quantity * current_price
      end

      raise Error.new(:awaiting_valuation) if market_value.negative?

      unit_value = market_value / quantity
      cost_basis = position.cost_basis
      unless cost_basis.nil? || (cost_basis.is_a?(BigDecimal) && cost_basis.finite? && cost_basis.positive?)
        cost_basis = nil
      end
      Position.new(
        isin: isin,
        mic: mic,
        name: metadata.description.to_s.presence || isin,
        quantity: quantity,
        market_value: market_value,
        price: unit_value,
        cost_basis: cost_basis,
        external_id: external_id(isin, mic, date),
        metadata: safe_position_metadata(position, metadata, isin, mic, date)
      )
    end

    def aggregate_positions(identity, rows)
      quantity = rows.sum(BigDecimal("0"), &:quantity)
      market_value = rows.sum(BigDecimal("0"), &:market_value)
      cost_basis = aggregate_cost_basis(rows, quantity)
      first = rows.first

      Position.new(
        isin: identity.first,
        mic: identity.last,
        name: first.name,
        quantity: quantity,
        market_value: market_value,
        price: market_value / quantity,
        cost_basis: cost_basis,
        external_id: first.external_id,
        metadata: rows.map(&:metadata).sort_by { |metadata| metadata.fetch("univoco") }
      )
    end

    def safe_position_metadata(position, instrument_metadata, isin, mic, snapshot_date)
      {
        "univoco" => position.univoco.to_s,
        "isin" => isin,
        "mic" => mic,
        "description" => instrument_metadata.description.to_s,
        "quote_currency" => instrument_metadata.currency.to_s,
        "quote_price" => position.current_price&.to_s("F"),
        "multiplier" => instrument_metadata.multiplier&.to_s("F"),
        "raw_multiplier" => instrument_metadata.raw_multiplier,
        "market_value" => position.market_value&.to_s("F"),
        "bank_average_price_raw" => bounded_raw_average_price(position.raw_average_price),
        "cost_basis" => position.cost_basis&.to_s("F"),
        "cost_basis_details" => position.cost_basis_details,
        "valuation_currency" => position.valuation_currency,
        "valuation_date" => position.valuation_date.iso8601,
        "snapshot_date" => snapshot_date.iso8601,
        "valuation_source" => position.valuation_source.to_s,
        "valuation_details" => position.valuation_details
      }.compact
    end

    def aggregate_cost_basis(rows, quantity)
      return unless rows.all? { |row| row.cost_basis.is_a?(BigDecimal) && row.cost_basis.finite? && row.cost_basis.positive? }

      products = rows.map do |row|
        Provider::Directa.bounded_decimal_result(row.quantity * row.cost_basis)
      end
      return if products.any?(&:nil?)

      total = products.sum(BigDecimal("0"))
      return unless total.finite? && total.positive?

      Provider::Directa.bounded_decimal_result(total / quantity)
    end

    def bounded_raw_average_price(value)
      return unless value.is_a?(String) && value.bytesize <= Provider::Directa::DECIMAL_MAX_INPUT_BYTES

      raw = value.strip
      return unless raw.ascii_only? && Provider::Directa::DECIMAL_PATTERN.match?(raw)

      raw
    end

    def zero_valued?(position)
      value = position.market_value
      value.nil? || (value.is_a?(BigDecimal) && value.zero?)
    end

    def decimal(value)
      result = case value
      when BigDecimal then value
      when Integer then BigDecimal(value.to_s)
      else
        raise Error.new(:invalid_snapshot)
      end

      raise Error.new(:invalid_snapshot) unless result.finite?

      result
    end

    def external_id(isin, mic, date)
      "directa-position-#{isin}-#{mic}-#{date.iso8601}"
    end

    def secure_equal?(left, right)
      return false if left.blank? || right.blank?
      return false unless left.to_s.bytesize == right.to_s.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
    end
end
