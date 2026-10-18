# frozen_string_literal: true

class Provider::Directa
  class ObservedValuation
    VALUE_SOURCE = "directa_bank_reference".freeze
    PRICE_SOURCE = "bank_reference".freeze
    PRICE_SOURCE_FIELD = "directa_listtit_prz_rif".freeze
    ACCOUNT_CURRENCY = "EUR".freeze

    STARTUP_MARKET_DESCRIPTIONS = {
      "P" => "MTA",
      "w" => "XETRA ETF/ETC",
      "B" => "MOT",
      "Q" => "NASDAQ"
    }.freeze

    INSTRUMENT_TUPLES = {
      [ "IM.", "M", "P", "3", "P", "EUR" ] => [ "XMIL", :ordinary ],
      [ "IM.", "M", "P", "5", "P", "EUR" ] => [ "XMIL", :ordinary ],
      [ "XT.", "V", "V", "x", "w", "EUR" ] => [ "XETR", :ordinary ],
      [ "IM.", "B", "B", "e", "B", "EUR" ] => [ "XMIL", :bond ],
      [ "NQ.", "O", "A", "", "Q", "USD" ] => [ "XNAS", :ordinary ]
    }.freeze

    ValuationTables = Data.define(:market_authorizations, :fx_rates, :fx_observed_at)

    def initialize(tables:)
      @tables = tables
    end

    def apply(snapshot)
      positions = snapshot.positions.map do |position|
        value_position(position, observed_at: snapshot.observed_at)
      end

      Snapshot.new(
        account_number: snapshot.account_number,
        account_identity: snapshot.account_identity,
        connection_generation: snapshot.connection_generation,
        observed_at: snapshot.observed_at,
        cash_seen: snapshot.cash_seen,
        positions_complete: snapshot.positions_complete,
        full_photo_complete: snapshot.full_photo_complete,
        cash: snapshot.cash,
        positions: positions,
        unknown_message_types: snapshot.unknown_message_types,
        field_sources: snapshot.field_sources
      )
    end

    def self.market_authorizations(table)
      return {}.freeze unless table.is_a?(Array) && table.length <= 2_000

      rows = Hash.new { |hash, key| hash[key] = { count: 0, description: nil, valid: true } }
      table.each do |row|
        next unless row.is_a?(Hash)

        code = row["serv"]
        next unless STARTUP_MARKET_DESCRIPTIONS.key?(code)

        item = rows[code]
        item[:count] += 1
        description = row["internalDescr"]
        expected = STARTUP_MARKET_DESCRIPTIONS.fetch(code)
        if !description.is_a?(String) || description != expected
          item[:valid] = false
        elsif item[:description] && item[:description] != expected
          item[:valid] = false
        else
          item[:description] = expected
        end
      end

      rows.each_with_object({}) do |(code, item), result|
        result[code] = item[:description] if item[:count] == 1 && item[:valid] && item[:description]
      end.freeze
    end

    def self.fx_rates(table)
      return {}.freeze unless table.is_a?(Array) && table.length <= 2_000

      rates = {}
      seen = {}
      duplicates = []
      table.each do |row|
        next unless row.is_a?(Hash)

        pair = row["currency"]
        next unless pair.is_a?(String) && pair.match?(/\A[A-Z]{3}EUR\z/)
        duplicates << pair if seen[pair]
        seen[pair] = true

        rate = decimal(row["cambioBCEdef"])
        next unless rate&.finite? && rate.positive?

        rates[pair] = rate
      end
      rates.except(*duplicates).freeze
    end

    def self.decimal(value)
      Provider::Directa.parse_decimal(value)
    end

    private

      def value_position(position, observed_at:)
        instrument = position.instrument_metadata
        identity = instrument && supported_identity(instrument)
        valued = identity && valuation_for(position, instrument, identity, observed_at: observed_at)
        enriched_metadata = if identity
          instrument.with_identity(mic: identity.first, identity_status: :verified)
        else
          instrument
        end
        basis = cost_basis_for(position, instrument, identity, observed_at: observed_at)

        Position.new(
          univoco: position.univoco,
          quantity: position.quantity,
          raw_quantity: position.raw_quantity,
          raw_average_price: position.raw_average_price,
          raw_fields: position.raw_fields,
          instrument_metadata: enriched_metadata,
          field_sources: position.field_sources,
          valuation_status: valued ? :verified : :unavailable,
          valuation_date: valued && observed_at.to_date,
          valuation_currency: valued && ACCOUNT_CURRENCY,
          current_price: valued && instrument.reference_price,
          market_value: valued && valued.fetch(:market_value),
          unrealized_gain: nil,
          valuation_source: valued && VALUE_SOURCE,
          valuation_details: valued && valued.fetch(:details),
          cost_basis: basis.fetch(:cost_basis),
          cost_basis_details: basis.fetch(:details)
        )
      end

      def supported_identity(instrument)
        return unless Provider::Directa.valid_isin?(instrument.isin)
        return unless instrument.currency&.match?(/\A[A-Z]{3}\z/)
        return unless instrument.instrument_type.is_a?(String)
        return unless instrument.multiplier.is_a?(BigDecimal) && instrument.multiplier.finite? && instrument.multiplier.positive?

        tuple = [
          instrument.canonical_code.to_s[0, 3],
          instrument.directa_market.to_s,
          instrument.phase.to_s,
          instrument.instrument_type,
          Array(instrument.authorization_markets).one? ? instrument.authorization_markets.first : nil,
          instrument.currency
        ]
        identity = INSTRUMENT_TUPLES[tuple]
        return unless identity
        authorization = tuple[4]
        return unless @tables.market_authorizations[authorization] == STARTUP_MARKET_DESCRIPTIONS.fetch(authorization)

        identity
      end

      def valuation_for(position, instrument, identity, observed_at:)
        quantity = decimal(position.quantity)
        reference_price = instrument.reference_price
        return unless quantity&.positive? && reference_price.is_a?(BigDecimal) && reference_price.finite? && reference_price.positive?
        return unless instrument.multiplier.is_a?(BigDecimal) && instrument.multiplier.finite? && instrument.multiplier.positive?

        denominator = identity.last == :bond ? BigDecimal("100") : BigDecimal("1")
        quote_value = Provider::Directa.bounded_decimal_result(
          quantity * instrument.multiplier * reference_price / denominator
        )
        return unless quote_value&.finite? && quote_value.positive?

        fx_pair = nil
        fx_rate = nil
        market_value = if instrument.currency == ACCOUNT_CURRENCY
          quote_value
        else
          fx_pair = "#{instrument.currency}EUR"
          fx_rate = @tables.fx_rates[fx_pair]
          return unless fx_rate.is_a?(BigDecimal) && fx_rate.finite? && fx_rate.positive?

          Provider::Directa.bounded_decimal_result(quote_value / fx_rate)
        end
        return unless market_value&.finite? && market_value.positive?

        {
          market_value: market_value,
          details: valuation_details(
            instrument,
            identity,
            fx_pair: fx_pair,
            fx_rate: fx_rate,
            observed_at: observed_at
          )
        }
      end

      def cost_basis_for(position, instrument, identity, observed_at:)
        return unavailable_cost_basis("unsupported_instrument_tuple") unless identity

        average_price = decimal(position.raw_average_price)
        return unavailable_cost_basis("missing_or_invalid_bank_average_price") unless average_price&.positive?
        return unavailable_cost_basis("unsupported_multiplier") unless instrument.multiplier == BigDecimal("1")

        denominator = identity.last == :bond ? BigDecimal("100") : BigDecimal("1")
        quote_basis = Provider::Directa.bounded_decimal_result(average_price / denominator)
        return unavailable_cost_basis("invalid_bank_average_price") unless quote_basis&.positive?

        details = {
          "cost_basis_source" => "bank_average_price",
          "bank_average_price" => average_price.to_s("F"),
          "bank_average_price_field" => Provider::Directa::FIELD_SOURCES.fetch(:position_average_price),
          "cost_basis_quote_currency" => instrument.currency,
          "cost_basis_multiplier" => instrument.multiplier.to_s("F"),
          "cost_basis_price_denominator" => denominator.to_s("F"),
          "cost_basis_observed_at" => observed_at.iso8601(6)
        }

        if instrument.currency == ACCOUNT_CURRENCY
          return { cost_basis: quote_basis, details: details.freeze }
        end

        fx_pair = "#{instrument.currency}EUR"
        fx_rate = @tables.fx_rates[fx_pair]
        return unavailable_cost_basis("missing_current_fx") unless fx_rate.is_a?(BigDecimal) && fx_rate.finite? && fx_rate.positive?

        basis = Provider::Directa.bounded_decimal_result(quote_basis / fx_rate)
        return unavailable_cost_basis("invalid_current_fx_basis") unless basis&.positive?

        details.merge!(
          "cost_basis_fx_source" => "current_fx",
          "cost_basis_fx_pair" => fx_pair,
          "cost_basis_fx_operation" => "divide",
          "cost_basis_fx_rate_source" => "cambioBCEdef",
          "cost_basis_fx_rate" => fx_rate.to_s("F"),
          "cost_basis_fx_observed_at" => @tables.fx_observed_at&.iso8601(6),
          "acquisition_fx_date" => "unknown"
        )
        { cost_basis: basis, details: details.freeze }
      end

      def unavailable_cost_basis(reason)
        {
          cost_basis: nil,
          details: {
            "cost_basis_source" => "bank_average_price",
            "cost_basis_status" => "unavailable",
            "cost_basis_unavailable_reason" => reason
          }.freeze
        }
      end

      def valuation_details(instrument, identity, fx_pair:, fx_rate:, observed_at:)
        details = {
          "price_source" => PRICE_SOURCE,
          "price_source_field" => PRICE_SOURCE_FIELD,
          "quote_trade_date" => "unknown",
          "quote_currency" => instrument.currency,
          "quote_price" => instrument.reference_price.to_s("F"),
          "multiplier" => instrument.multiplier.to_s("F"),
          "price_denominator" => identity.last == :bond ? "100" : "1",
          "snapshot_observed_at" => observed_at.iso8601(6)
        }
        if fx_pair
          details.merge!(
            "fx_pair" => fx_pair,
            "fx_from_currency" => instrument.currency,
            "fx_to_currency" => ACCOUNT_CURRENCY,
            "fx_operation" => "divide",
            "fx_rate_source" => "cambioBCEdef",
            "fx_rate" => fx_rate.to_s("F"),
            "fx_observed_at" => @tables.fx_observed_at&.iso8601(6),
            "fx_effective_date" => "unknown"
          )
        end
        details.freeze
      end

      def decimal(value)
        Provider::Directa.parse_decimal(value)
      end
  end
end
