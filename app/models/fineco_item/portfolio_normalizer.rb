class FinecoItem::PortfolioNormalizer
  Position = Data.define(
    :isin,
    :mic,
    :name,
    :quantity,
    :market_value,
    :book_value,
    :profit_loss,
    :effective_price,
    :cost_basis,
    :quote_currency,
    :quote_price,
    :average_price,
    :accrual,
    :ongoing_accrual,
    :instrument_type,
    :position_type
  )

  Snapshot = Data.define(:date, :captured_at, :currency, :positions, :market_value)

  MIC_MAP = {
    "XETR" => "XETR",
    "XETRA" => "XETR",
    "ETLX" => "ETLX"
  }.freeze

  POSITION_FIELDS = %w[instrId venueSystem currencyCd qty marketPrice bookValue marketValue profitLoss type].freeze
  SUMMARY_MONEY_FIELDS = %w[bookValue marketValue profitLoss accrual].freeze
  FILTER_GROUPS = %w[currencies instrumentTypes].freeze
  SUPPORTED_POSITION_TYPES = %w[stock equity etf bond].freeze
  FILTER_VALUE_PATTERN = /\A[\p{Alnum}_.-]{1,32}\z/
  ISIN_PATTERN = /\A[A-Z]{2}[A-Z0-9]{9}[0-9]\z/

  def initialize(payload:, captured_at:)
    @payload = payload
    @captured_at = captured_at
  end

  def normalize
    validate_dossier!
    validate_filters!
    positions = normalize_positions
    summary_total = summary_total!
    validate_summary!(summary_total, positions)

    Snapshot.new(
      date: snapshot_date,
      captured_at: snapshot_timestamp,
      currency: "EUR",
      positions: positions,
      market_value: positions.sum(BigDecimal("0"), &:market_value)
    )
  rescue FinecoItem::PortfolioImportError
    raise
  rescue StandardError
    raise FinecoItem::PortfolioImportError.new(:invalid_snapshot), cause: nil
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

    def validate_dossier!
      dossier = @payload.dig("info", "dossier") if @payload.is_a?(Hash)
      raise FinecoItem::PortfolioImportError.new(:invalid_snapshot) unless dossier.is_a?(Hash) && dossier["blocked"] == false
    end

    def validate_filters!
      filters = @payload["filters"]
      raise FinecoItem::PortfolioImportError.new(:invalid_snapshot) unless filters.is_a?(Hash)

      FILTER_GROUPS.each do |group_name|
        group = filters[group_name]
        unless group.is_a?(Hash) && group["total"].is_a?(Array) && group["show"].is_a?(Array)
          raise FinecoItem::PortfolioImportError.new(:invalid_snapshot)
        end

        total = normalize_filter_values(group["total"])
        show = normalize_filter_values(group["show"])
        raise FinecoItem::PortfolioImportError.new(:partial_snapshot) unless total == show
      end
    end

    def normalize_filter_values(values)
      unless values.size <= Provider::Fineco::MAX_FILTER_VALUE_COUNT &&
             values.all? { |value| value.is_a?(String) && value.match?(FILTER_VALUE_PATTERN) }
        raise FinecoItem::PortfolioImportError.new(:invalid_snapshot)
      end

      normalized = values.map(&:strip)
      raise FinecoItem::PortfolioImportError.new(:invalid_snapshot) unless normalized.uniq.size == normalized.size

      normalized.sort
    end

    def normalize_positions
      positions = @payload.dig("positions", "show")
      unless positions.is_a?(Array) && positions.size <= Provider::Fineco::MAX_POSITION_COUNT
        raise FinecoItem::PortfolioImportError.new(:invalid_snapshot)
      end

      normalized = positions.map { |position| normalize_position(position) }
      keys = normalized.map(&:isin)
      raise FinecoItem::PortfolioImportError.new(:duplicate_position) unless keys.uniq.size == keys.size

      normalized
    end

    def normalize_position(position)
      unless position.is_a?(Hash) && POSITION_FIELDS.all? { |field| position.key?(field) }
        raise FinecoItem::PortfolioImportError.new(:unsupported_position)
      end

      isin = position["instrId"].to_s.upcase
      unless self.class.valid_isin?(isin)
        raise FinecoItem::PortfolioImportError.new(:unsupported_position)
      end

      mic = MIC_MAP[position["venueSystem"].to_s.upcase]
      unless mic.present? && Security::EXCHANGES.key?(mic)
        raise FinecoItem::PortfolioImportError.new(:unsupported_position)
      end

      quote_currency = position["currencyCd"]
      unless quote_currency.is_a?(String) && quote_currency.match?(/\A[A-Za-z]{3}\z/)
        raise FinecoItem::PortfolioImportError.new(:unsupported_position)
      end

      position_type = position["type"].to_s.downcase
      unless SUPPORTED_POSITION_TYPES.include?(position_type)
        raise FinecoItem::PortfolioImportError.new(:unsupported_position)
      end

      quantity = decimal(position["qty"])
      market_value = decimal(position["marketValue"])
      book_value = decimal(position["bookValue"])
      profit_loss = decimal(position["profitLoss"])
      quote_price = decimal(position["marketPrice"])
      average_price = optional_decimal(position["avgPrice"])
      accrual = optional_decimal(position["accrual"]) || BigDecimal("0")
      ongoing_accrual = optional_decimal(position["ongoingAccrual"]) || BigDecimal("0")

      if quantity.negative? || market_value.negative? || book_value.negative? || quote_price.negative?
        raise FinecoItem::PortfolioImportError.new(:unsupported_position)
      end
      if quantity.zero? && [ market_value, book_value, profit_loss ].any?(&:nonzero?)
        raise FinecoItem::PortfolioImportError.new(:unsupported_position)
      end

      effective_price = quantity.zero? ? BigDecimal("0") : market_value / quantity
      cost_basis = quantity.zero? ? BigDecimal("0") : book_value / quantity
      name = position["description"].presence || position["symbol"].presence || isin

      Position.new(
        isin: isin,
        mic: mic,
        name: name.to_s.truncate(200),
        quantity: quantity,
        market_value: market_value,
        book_value: book_value,
        profit_loss: profit_loss,
        effective_price: effective_price,
        cost_basis: cost_basis,
        quote_currency: quote_currency.upcase,
        quote_price: quote_price,
        average_price: average_price,
        accrual: accrual,
        ongoing_accrual: ongoing_accrual,
        instrument_type: bounded_string(position["instrType"]),
        position_type: position_type
      )
    rescue ArgumentError
      raise FinecoItem::PortfolioImportError.new(:unsupported_position), cause: nil
    end

    def summary_total!
      summary = @payload["summary"]
      total = summary.is_a?(Hash) ? summary["total"] : nil
      show = summary.is_a?(Hash) ? summary["show"] : nil
      unless total.is_a?(Hash) && show.is_a?(Hash) && total["currencyCd"] == "EUR" && show["currencyCd"] == "EUR"
        raise FinecoItem::PortfolioImportError.new(:invalid_snapshot)
      end

      SUMMARY_MONEY_FIELDS.each do |field|
        raise FinecoItem::PortfolioImportError.new(:invalid_snapshot) unless total.key?(field) && show.key?(field)
        if (decimal(total[field]) - decimal(show[field])).abs > BigDecimal("0.005")
          raise FinecoItem::PortfolioImportError.new(:partial_snapshot)
        end
      end

      [ "profitLossPerc" ].each do |field|
        if (decimal(total[field]) - decimal(show[field])).abs > BigDecimal("0.01")
          raise FinecoItem::PortfolioImportError.new(:partial_snapshot)
        end
      end

      total
    end

    def validate_summary!(total, positions)
      tolerance = BigDecimal("0.005") * (positions.size + 1)
      SUMMARY_MONEY_FIELDS.each do |field|
        sum = case field
        when "bookValue" then positions.sum(BigDecimal("0"), &:book_value)
        when "marketValue" then positions.sum(BigDecimal("0"), &:market_value)
        when "profitLoss" then positions.sum(BigDecimal("0"), &:profit_loss)
        when "accrual" then positions.sum(BigDecimal("0"), &:accrual)
        end
        if (sum - decimal(total[field])).abs > tolerance
          raise FinecoItem::PortfolioImportError.new(:partial_snapshot)
        end
      end
    end

    def decimal(value)
      parsed = case value
      when BigDecimal then value
      when Integer, Float then BigDecimal(value.to_s)
      when String then BigDecimal(value)
      else
        raise ArgumentError
      end
      raise ArgumentError unless parsed.finite?

      parsed
    end

    def optional_decimal(value)
      return nil if value.nil?

      decimal(value)
    end

    def bounded_string(value)
      value.to_s.strip.presence&.truncate(80)
    end

    def snapshot_date
      snapshot_timestamp.to_date
    end

    def snapshot_timestamp
      time = @captured_at.respond_to?(:in_time_zone) ? @captured_at.in_time_zone : Time.zone.parse(@captured_at.to_s)
      raise FinecoItem::PortfolioImportError.new(:invalid_snapshot) unless time.present?

      time
    end
end
