module IbkrAccount::DataHelpers
  extend ActiveSupport::Concern

  # IBKR quotes a bond as a percentage of its face value, and a bond's position
  # or trade quantity is that face value; its multiplier (0.01) relates the two.
  # Sure counts every bond in units of 100 face, the unit its price is quoted
  # per, so the price reads as IBKR quotes it and quantity x price is its value.
  #
  # The unit is fixed rather than decided from the report. A sync imports only
  # its own window and never rescales a trade stored by an earlier one, so a
  # unit that depended on the rows of the current report could differ from the
  # unit a bond's earlier trades were stored in. What does depend on the row is
  # the price: it is the one that makes quantity x price the value IBKR reports
  # for the row (see #price_scale). That is the quoted price for an ordinary
  # bond, and carries an inflation index ratio, a pool factor or a quote per
  # unit instead of per 100 face into the price for any other.
  BOND_MULTIPLIER = BigDecimal("0.01")

  # How far a bond's price may sit from the quoted one, as a share of it,
  # before the row is reported. The reported value is rounded to cents, so a
  # lot of a few units can be reported from rounding alone.
  BOND_PRICE_TOLERANCE = BigDecimal("0.001")

  # A bond is tracked under this prefix, its IBKR symbol and its contract id
  # (conid), as "BOND:<symbol>:<conid>". Trades carry no ISIN, and two bonds
  # can share a symbol, so the conid keeps them apart. The prefix keeps a bond
  # off a listed security that shares the symbol, and off that security's prices.
  BOND_TICKER_PREFIX = "BOND:"

  # No price provider quotes a bond per 100 face, so a bond is offline and
  # valued at IBKR's mark and trade prices. The reason says which flow set it.
  BOND_OFFLINE_REASON = "ibkr_bond"

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.delete(",").strip : value.to_s
      return nil if normalized.blank? || normalized == "-"

      # Convert accounting parentheses notation: "(1234.56)" → "-1234.56"
      normalized = "-#{normalized[1..-2]}" if normalized.start_with?("(") && normalized.end_with?(")")

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      return nil if value.blank?

      case value
      when Date
        value
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.to_date
      else
        normalized = value.to_s.tr(";", " ")
        Time.zone.parse(normalized)&.to_date || Date.parse(normalized)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def parse_datetime(value)
      return nil if value.blank?

      case value
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.in_time_zone
      when Date
        value.in_time_zone
      else
        Time.zone.parse(value.to_s.tr(";", " "))
      end
    rescue ArgumentError, TypeError
      nil
    end

    def resolve_security(row)
      data = row.with_indifferent_access
      return resolve_bond_security(data) if bond?(data)

      ticker = data[:symbol].to_s.strip.upcase
      return nil if ticker.blank?

      Security.find_by(ticker: ticker) || create_security_from_row(ticker)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    def trade_date_for(row)
      data = row.with_indifferent_access
      parsed_trade_date = parse_date(data[:trade_date])
      return parsed_trade_date if parsed_trade_date

      Rails.logger.warn(
        "IbkrAccount::DataHelpers - Missing or invalid trade_date, falling back to Date.current. " \
        "trade_id=#{data[:trade_id].inspect}"
      )
      Date.current
    end

    def extract_currency(row, fallback: nil)
      value = row.with_indifferent_access[:currency]
      value.present? ? value.to_s.upcase : fallback
    end

    def create_security_from_row(ticker)
      Security.create!(ticker: ticker, name: ticker)
    end

    def bond?(row)
      asset_category(row) == "BOND"
    end

    # What one unit of the row's quantity counts as in Sure: a bond's face
    # value counts per 100 face, anything else as IBKR reports it.
    def quantity_multiplier(row)
      bond?(row) ? BOND_MULTIPLIER : BigDecimal("1")
    end

    # What a bond row's quoted price is multiplied by so that quantity x price
    # x 0.01 is the value the row reports (positionValue for a position,
    # proceeds or tradeMoney for a trade): 1 for a row quoted per 100 face, 100
    # for one quoted per unit, the index ratio or pool factor for a principal-
    # adjusted bond. Accrued interest is booked as its own cash row (see the
    # fixture), and the trade and position values are taken to be clean, so the
    # quoted price is not moved by it. If a value does include some, it is
    # carried into the price, a small deviation. 1 for a row with no usable
    # value, and for anything but a bond.
    def price_scale(row)
      return BigDecimal("1") unless bond?(row)

      data = row.with_indifferent_access
      quantity = parse_decimal(data[:position] || data[:quantity])
      price = parse_decimal(data[:mark_price] || data[:trade_price])
      value = [ data[:position_value], data[:proceeds], data[:trade_money] ]
        .filter_map { |v| parse_decimal(v) }.find { |v| v.finite? && !v.zero? }
      return BigDecimal("1") unless quantity&.finite? && price&.finite? && value && !quantity.zero? && !price.zero?

      scale = value.abs / (quantity.abs * BOND_MULTIPLIER * price.abs)
      scale.finite? && scale.positive? ? scale : BigDecimal("1")
    end

    # For each bond with rows of this kind (:positions or :trades) whose price
    # was moved off the quoted one: its ticker, its unit and the factors the
    # prices were multiplied by. What a debug entry reports.
    def bond_unit_disagreements(kind)
      rows = kind == :positions ? raw_position_rows.select { |row| row[:side].to_s == "Long" } : raw_trade_rows
      factors = bond_rows(rows).map { |row| [ bond_ticker(row), price_scale(row) ] }
      factors.group_by(&:first).filter_map do |ticker, pairs|
        moved = pairs.map(&:last).reject { |scale| (scale - 1).abs <= BOND_PRICE_TOLERANCE }
        { ticker: ticker, unit_factor: BOND_MULTIPLIER.to_s("F"), differing_rows: moved.size, row_price_factors: moved.uniq.map { |f| f.round(6).to_s("F") } } if moved.any?
      end
    end

    def raw_position_rows
      Array(@ibkr_account.raw_holdings_payload).map(&:with_indifferent_access)
    end

    def raw_trade_rows
      Array((@ibkr_account.raw_activities_payload || {}).with_indifferent_access[:trades]).map(&:with_indifferent_access)
    end

    def bond_rows(rows)
      rows.select { |row| bond?(row) && bond_ticker(row) }
    end

    def asset_category(row)
      row.with_indifferent_access[:asset_category].to_s.strip.upcase
    end

    # The ticker a bond's rows are tracked under, nil when the row lacks the
    # symbol or contract id that names it.
    def bond_ticker(row)
      symbol = row[:symbol].to_s.strip.upcase
      conid = row[:conid].to_s.strip
      "#{BOND_TICKER_PREFIX}#{symbol}:#{conid}" unless symbol.blank? || conid.blank?
    end

    # Securities are global, so an existing row is reused as it stands. The
    # savepoint keeps a lost create race from aborting the import around it.
    def resolve_bond_security(data)
      return nil unless bond_ticker(data)

      ticker = bond_ticker(data)
      Security.find_by(ticker: ticker) || Security.transaction(requires_new: true) do
        Security.create!(
          ticker: ticker,
          name: data[:description].to_s.strip.presence || data[:symbol].to_s.strip.upcase,
          offline: true,
          offline_reason: BOND_OFFLINE_REASON
        )
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end
end
