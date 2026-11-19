module IbkrAccount::DataHelpers
  extend ActiveSupport::Concern

  # IBKR quotes a bond as a percentage of its face value, and a bond's position
  # or trade quantity is that face value; its multiplier (0.01) relates the two.
  # Sure counts a bond in units of 100 face, the unit its price is quoted per,
  # so the price reads as IBKR quotes it and quantity x price is its value. A
  # Flex Query without the Multiplier field is no different: the row's value
  # decides between a unit of 1 and of 0.01, and 0.01 (IBKR's bond multiplier)
  # is the fallback when the row has no value to decide with.
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
    # value times its unit factor, anything else as IBKR reports it.
    #
    # A bond's unit is read from the row's own value, not from its multiplier
    # alone: IBKR's documentation does not say what the multiplier of a bond is
    # (0.01 or the generic 1), and trusting a 1 would value a bond 100 times too
    # high. The factor that makes quantity x price equal the reported value
    # (positionValue for a position, proceeds or tradeMoney for a trade) is
    # matched to the reported multiplier, 1 and 0.01. A row with no value to
    # check against counts per 100 face.
    def quantity_multiplier(row)
      return BigDecimal("1") unless bond?(row)

      data = row.with_indifferent_access
      implied = implied_unit_factor(data)
      return BOND_MULTIPLIER unless implied

      reported = parse_decimal(data[:multiplier])
      candidates = [ reported, BigDecimal("1"), BOND_MULTIPLIER ].select { |c| c&.positive? }
      best = candidates.min_by { |c| (Math.log10(implied.to_f) - Math.log10(c.to_f)).abs }
      close = (Math.log10(implied.to_f) - Math.log10(best.to_f)).abs <= BOND_UNIT_TOLERANCE
      close ? best : BOND_MULTIPLIER
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

    # Securities are global, so an existing row is reused as it stands. The
    # savepoint keeps a lost create race from aborting the import around it.
    def resolve_bond_security(data)
      symbol = data[:symbol].to_s.strip.upcase
      conid = data[:conid].to_s.strip
      return nil if symbol.blank? || conid.blank?

      ticker = "#{BOND_TICKER_PREFIX}#{symbol}:#{conid}"
      Security.find_by(ticker: ticker) || Security.transaction(requires_new: true) do
        Security.create!(
          ticker: ticker,
          name: data[:description].to_s.strip.presence || symbol,
          offline: true,
          offline_reason: BOND_OFFLINE_REASON
        )
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end
end
