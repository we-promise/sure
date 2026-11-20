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
  # the price: IBKR's documentation does not say what the multiplier of a bond
  # is (0.01 or the generic 1), so a row whose own value says it is quoted per
  # unit, or per anything else, has its price carried into the 100 face unit,
  # and quantity x price stays the value IBKR reported (see #price_scale).
  BOND_MULTIPLIER = BigDecimal("0.01")

  # How far, in orders of magnitude, a bond's implied unit factor may sit from
  # a candidate (the reported multiplier, 1 or 0.01) to count as that one.
  BOND_UNIT_TOLERANCE = 0.5

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

    # What a row's own price is multiplied by to read per 100 face: 1 for a
    # row quoted that way, 100 for one quoted per unit. Decided by the row alone,
    # so a bond reads the same whichever sync imports it. 1 for a row with no
    # value to tell, and for anything but a bond.
    def price_scale(row)
      return BigDecimal("1") unless bond?(row)

      row_unit_factor(row)&.then { |factor| factor / BOND_MULTIPLIER } || BigDecimal("1")
    end

    # For each bond with rows of this kind (:positions or :trades) quoted in
    # another unit than per 100 face: its ticker, that unit and the factors of
    # the rows that were carried into it. What a debug entry reports.
    def bond_unit_disagreements(kind)
      rows = kind == :positions ? raw_position_rows.select { |row| row[:side].to_s == "Long" } : raw_trade_rows
      factors = bond_rows(rows).filter_map { |row| [ bond_ticker(row), row_unit_factor(row) ] }
      factors.group_by(&:first).filter_map do |ticker, pairs|
        others = pairs.map(&:last).compact.reject { |factor| factor == BOND_MULTIPLIER }
        { ticker: ticker, unit_factor: BOND_MULTIPLIER.to_s("F"), differing_rows: others.size, row_unit_factors: others.uniq.map { |f| f.to_s("F") } } if others.any?
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

    # The factor one row's own value implies, matched to the multiplier it
    # reports, 1 and 0.01 -- the one that makes quantity x price equal the
    # reported value (positionValue for a position, proceeds or tradeMoney for
    # a trade). Nil for a row with nothing to check it against, or whose value
    # fits none of them.
    def row_unit_factor(row)
      data = row.with_indifferent_access
      implied = implied_unit_factor(data)
      return nil unless implied

      reported = parse_decimal(data[:multiplier])
      candidates = [ reported, BigDecimal("1"), BOND_MULTIPLIER ].select { |c| c&.positive? }
      best = candidates.min_by { |c| (Math.log10(implied.to_f) - Math.log10(c.to_f)).abs }
      best if (Math.log10(implied.to_f) - Math.log10(best.to_f)).abs <= BOND_UNIT_TOLERANCE
    end

    # |value| / (|quantity| x |price|) for a position or a trade row, nil when
    # the row lacks a figure to work it out from. Accrued interest and a bond's
    # value factor move it a little, which the tolerance absorbs.
    def implied_unit_factor(data)
      quantity = parse_decimal(data[:position] || data[:quantity])
      price = parse_decimal(data[:mark_price] || data[:trade_price])
      value = [ data[:position_value], data[:proceeds], data[:trade_money] ]
        .filter_map { |v| parse_decimal(v) }.find { |v| !v.zero? }
      return nil unless quantity && price && value && !quantity.zero? && !price.zero?

      factor = value.abs / (quantity.abs * price.abs)
      factor.finite? ? factor : nil
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
