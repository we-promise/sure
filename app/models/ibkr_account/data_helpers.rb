module IbkrAccount::DataHelpers
  extend ActiveSupport::Concern

  # IBKR quotes a bond as a percentage of its face value, and a bond's position
  # or trade quantity is that face value; its multiplier (0.01) relates the two.
  # Sure counts a bond in units of 100 face, the unit its price is quoted per,
  # so the price reads as IBKR quotes it and quantity x price is its value. A
  # Flex Query without the Multiplier field is no different: a row's value
  # decides between a unit of 1 and of 0.01, and 0.01 (IBKR's bond multiplier)
  # is the fallback when no row has a value to decide with.
  #
  # One bond security has one unit, for every row of it (see bond_unit_factors).
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

    # What one unit of the row's quantity counts as in Sure: for a bond, its
    # face value times the unit factor of the bond's security, for anything
    # else as IBKR reports it. Every row of one bond security shares that
    # factor, so the holding, its trades and the prices between them are in one
    # unit; see #bond_unit_factors and #price_scale.
    def quantity_multiplier(row)
      return BigDecimal("1") unless bond?(row)

      bond_unit_factors.fetch(bond_ticker(row.with_indifferent_access), nil) || row_unit_factor(row) || BOND_MULTIPLIER
    end

    # What a row's own price is multiplied by to read in its security's unit:
    # a row that counts differently from its bond (a trade quoted per 100 face
    # against a position counted per unit, say) keeps its total value, quantity
    # and price moving together. 1 for any row that agrees with its security,
    # for one with no value to tell, and for anything but a bond.
    def price_scale(row)
      return BigDecimal("1") unless bond?(row)

      own = row_unit_factor(row)
      shared = bond_unit_factors.fetch(bond_ticker(row.with_indifferent_access), nil)
      own && shared ? own / shared : BigDecimal("1")
    end

    # The unit factor each bond security is counted in, by its ticker, decided
    # once for the whole report so that no row of a security differs from
    # another. IBKR's documentation does not say what the multiplier of a bond
    # is (0.01 or the generic 1), and trusting a 1 would value a bond 100 times
    # too high, so each row's factor is read from its own value (see
    # #row_unit_factor), then:
    # - the open position decides, since the holdings must reconcile with
    #   IBKR's positionValue;
    # - a bond with no position (one sold since) takes its trades' factor;
    # - the factor most rows imply wins, and a tie goes to 0.01.
    # A bond none of whose rows has a value to check counts per 100 face.
    def bond_unit_factors
      @bond_unit_factors ||= bond_unit_votes.transform_values do |votes|
        tally(votes[:positions]) || tally(votes[:trades])
      end.compact
    end

    # For each bond whose rows of this kind (:positions or :trades) differ from
    # the factor it is counted in: its ticker, that factor and the differing
    # rows' factors. What a debug entry reports.
    def bond_unit_disagreements(kind)
      bond_unit_votes.filter_map do |ticker, votes|
        shared = bond_unit_factors[ticker]
        others = votes[kind].reject { |factor| factor == shared }
        { ticker: ticker, unit_factor: shared.to_s("F"), differing_rows: others.size, row_unit_factors: others.uniq.map { |f| f.to_s("F") } } if shared && others.any?
      end
    end

    def bond_unit_votes
      @bond_unit_votes ||= begin
        votes = Hash.new { |hash, ticker| hash[ticker] = { positions: [], trades: [] } }
        # A short position is not imported, so it says nothing of the unit.
        bond_rows(raw_position_rows).select { |row| row[:side].to_s == "Long" }.each { |row| add_vote(votes, row, :positions) }
        bond_rows(raw_trade_rows).each { |row| add_vote(votes, row, :trades) }
        votes
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

    def add_vote(votes, row, kind)
      factor = row_unit_factor(row)
      votes[bond_ticker(row)][kind] << factor if factor
    end

    # The factor with the most votes, a tie going to 0.01; nil with no votes.
    def tally(factors)
      return nil if factors.empty?

      counts = factors.tally
      top = counts.values.max
      leaders = counts.select { |_, count| count == top }.keys
      leaders.include?(BOND_MULTIPLIER) ? BOND_MULTIPLIER : leaders.first
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
