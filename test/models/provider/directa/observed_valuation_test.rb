require "test_helper"

class Provider::Directa::ObservedValuationTest < ActiveSupport::TestCase
  test "values supported ordinary shares and percent quoted bonds using bank reference prices" do
    observed_at = Time.utc(2026, 10, 18, 8, 30)
    positions = [
      position(
        code: "IM.ETF",
        currency: "EUR",
        market: "M",
        phase: "P",
        instrument_type: "3",
        authorization: "P",
        quantity: 2,
        multiplier: "1.5",
        reference_price: "100"
      ),
      position(
        code: "IM.BOND",
        currency: "EUR",
        market: "B",
        phase: "B",
        instrument_type: "e",
        authorization: "B",
        quantity: 5,
        multiplier: "1.25",
        reference_price: "96"
      ),
      position(
        code: "NQ.STOCK",
        currency: "USD",
        market: "O",
        phase: "A",
        instrument_type: "",
        authorization: "Q",
        quantity: 2,
        multiplier: "1.5",
        reference_price: "100"
      )
    ]

    valued = valuer(fx_rates: { "USDEUR" => BigDecimal("1.25") }).apply(snapshot(positions, observed_at: observed_at))

    assert_equal [ BigDecimal("300"), BigDecimal("6"), BigDecimal("240") ], valued.positions.map(&:market_value)
    assert_equal [ "XMIL", "XMIL", "XNAS" ], valued.positions.map { |position| position.instrument_metadata.mic }
    assert_equal [ :verified, :verified, :verified ], valued.positions.map(&:identity_status)
    assert_equal [ :verified, :verified, :verified ], valued.positions.map(&:valuation_status)
    assert_equal observed_at.to_date, valued.positions.first.valuation_date
    assert_equal "directa_bank_reference", valued.positions.last.valuation_source
    assert_nil valued.positions.last.unrealized_gain
    assert_equal "bank_reference", valued.positions.last.valuation_details.fetch("price_source")
    assert_equal "directa_listtit_prz_rif", valued.positions.last.valuation_details.fetch("price_source_field")
    assert_equal "100.0", valued.positions.last.valuation_details.fetch("quote_price")
    assert_equal "1.5", valued.positions.last.valuation_details.fetch("multiplier")
    assert_equal "unknown", valued.positions.last.valuation_details.fetch("quote_trade_date")
    assert_equal "USDEUR", valued.positions.last.valuation_details.fetch("fx_pair")
    assert_equal "divide", valued.positions.last.valuation_details.fetch("fx_operation")
    assert_equal "1.25", valued.positions.last.valuation_details.fetch("fx_rate")
    assert_equal "unknown", valued.positions.last.valuation_details.fetch("fx_effective_date")
    assert_equal "100.0", valued.positions.first.valuation_details.fetch("quote_price")
    assert_equal "1", valued.positions.first.valuation_details.fetch("price_denominator")
    assert_equal "100", valued.positions.second.valuation_details.fetch("price_denominator")
    assert_equal observed_at, valued.observed_at
  end

  test "leaves a foreign position unvalued without its exact bootstrap FX pair" do
    position = position(
      code: "NQ.STOCK",
      currency: "USD",
      market: "O",
      phase: "A",
      instrument_type: "",
      authorization: "Q",
      quantity: 1,
      multiplier: "1",
      reference_price: "50"
    )

    valued = valuer(fx_rates: {}).apply(snapshot([ position ]))

    assert_equal :verified, valued.positions.first.identity_status
    assert_nil valued.positions.first.market_value
    assert_equal :unavailable, valued.positions.first.valuation_status
  end

  test "rejects extreme bootstrap FX exponents and refuses foreign valuation" do
    rates = Provider::Directa::ObservedValuation.fx_rates([
      { "currency" => "USDEUR", "cambioBCEdef" => "1e1000000000" }
    ])
    position = position(
      code: "NQ.STOCK",
      currency: "USD",
      market: "O",
      phase: "A",
      instrument_type: "",
      authorization: "Q",
      quantity: 1,
      multiplier: "1",
      reference_price: "50"
    )

    valued = valuer(fx_rates: rates).apply(snapshot([ position ]))

    assert_nil Provider::Directa::ObservedValuation.decimal("1e-1000000000")
    assert_empty rates
    assert_nil valued.positions.first.market_value
    assert_equal :unavailable, valued.positions.first.valuation_status
  end

  test "preserves a bounded nonterminating USD conversion result" do
    rates = Provider::Directa::ObservedValuation.fx_rates([
      { "currency" => "USDEUR", "cambioBCEdef" => 1.1236 }
    ])
    position = position(
      code: "NQ.STOCK",
      currency: "USD",
      market: "O",
      phase: "A",
      instrument_type: "",
      authorization: "Q",
      quantity: 23,
      multiplier: "1",
      reference_price: "6.85"
    )

    valued = valuer(fx_rates: rates).apply(snapshot([ position ])).positions.first
    expected = BigDecimal("23") * BigDecimal("1") * BigDecimal("6.85") / BigDecimal("1.1236")

    assert_equal expected, valued.market_value
    assert_equal "1.1236", valued.valuation_details.fetch("fx_rate")
    assert_equal :verified, valued.valuation_status
  end

  test "rejects unsupported tuples and invalid nonpositive price inputs" do
    unsupported = position(
      code: "NQ.STOCK",
      currency: "USD",
      market: "O",
      phase: "A",
      instrument_type: "x",
      authorization: "Q",
      quantity: 1,
      multiplier: "1",
      reference_price: "50"
    )
    invalid_price = position(
      code: "IM.ETF",
      currency: "EUR",
      market: "M",
      phase: "P",
      instrument_type: "3",
      authorization: "P",
      quantity: 1,
      multiplier: "0",
      reference_price: "50"
    )
    nonfinite_price = position(
      code: "IM.ETF",
      currency: "EUR",
      market: "M",
      phase: "P",
      instrument_type: "3",
      authorization: "P",
      quantity: 1,
      multiplier: "1",
      reference_price: "Infinity"
    )

    valued = valuer(fx_rates: {}).apply(snapshot([ unsupported, invalid_price, nonfinite_price ]))

    assert_equal :partial, valued.positions.first.identity_status
    assert_nil valued.positions.first.instrument_metadata.mic
    assert_equal :unavailable, valued.positions.first.valuation_status
    assert_equal :partial, valued.positions.second.identity_status
    assert_nil valued.positions.second.market_value
    assert_equal :verified, valued.positions.third.identity_status
    assert_nil valued.positions.third.market_value
    assert_equal :unavailable, valued.positions.third.valuation_status
  end

  test "requires an explicit empty Nasdaq instrument type" do
    missing_type = position(
      code: "NQ.STOCK",
      currency: "USD",
      market: "O",
      phase: "A",
      instrument_type: nil,
      authorization: "Q",
      quantity: 1,
      multiplier: "1",
      reference_price: "50"
    )
    explicit_empty_type = position(
      code: "NQ.STOCK",
      currency: "USD",
      market: "O",
      phase: "A",
      instrument_type: "",
      authorization: "Q",
      quantity: 1,
      multiplier: "1",
      reference_price: "50"
    )

    valued = valuer(fx_rates: { "USDEUR" => BigDecimal("1.25") }).apply(
      snapshot([ missing_type, explicit_empty_type ])
    )

    assert_equal :partial, valued.positions.first.identity_status
    assert_nil valued.positions.first.instrument_metadata.mic
    assert_equal :verified, valued.positions.second.identity_status
    assert_equal BigDecimal("40"), valued.positions.second.market_value
  end

  test "rejects duplicate and malformed bootstrap market or FX rows" do
    market_table = [
      { "serv" => "P", "internalDescr" => "MTA", "codAbilPrz" => "R" },
      { "serv" => "P", "codAbilPrz" => "R" },
      { "serv" => "B", "internalDescr" => "MOT", "codAbilPrz" => "R" },
      { "serv" => "w", "internalDescr" => "XETRA ETF/ETC", "codAbilPrz" => "R" },
      { "serv" => "Q", "internalDescr" => "NASDAQ", "codAbilPrz" => "R" },
      { "serv" => "V", "internalDescr" => "XETRA", "codAbilPrz" => "D" }
    ]
    fx_table = [
      { "currency" => "USDEUR", "cambioBCEdef" => "not-a-rate" },
      { "currency" => "USDEUR", "cambioBCEdef" => 1.25 },
      { "currency" => "GBPEUR", "cambioBCEdef" => Float::INFINITY }
    ]

    assert_equal(
      { "B" => "MOT", "w" => "XETRA ETF/ETC", "Q" => "NASDAQ" },
      Provider::Directa::ObservedValuation.market_authorizations(market_table)
    )
    assert_equal(
      BigDecimal("1.1236"),
      Provider::Directa::ObservedValuation.fx_rates([
        { "currency" => "USDEUR", "euroBid" => 0.89, "euroAsk" => 0.90, "cambioBCEdef" => 1.1236 }
      ]).fetch("USDEUR")
    )
    assert_empty Provider::Directa::ObservedValuation.fx_rates(fx_table)
  end

  private

    def valuer(fx_rates:)
      tables = Provider::Directa::ObservedValuation::ValuationTables.new(
        market_authorizations: {
          "P" => "MTA",
          "w" => "XETRA ETF/ETC",
          "B" => "MOT",
          "Q" => "NASDAQ"
        },
        fx_rates: fx_rates,
        fx_observed_at: Time.utc(2026, 10, 18, 8, 31)
      )
      Provider::Directa::ObservedValuation.new(tables: tables)
    end

    def snapshot(positions, observed_at: Time.utc(2026, 10, 18, 8, 30))
      Provider::Directa::Snapshot.new(
        account_number: "00123",
        account_identity: "123",
        connection_generation: 1,
        observed_at: observed_at,
        cash_seen: true,
        positions_complete: true,
        full_photo_complete: false,
        cash: Provider::Directa::Cash.new(
          amount: BigDecimal("20"),
          raw_amount: "20",
          equity_availability: nil,
          equity_margin_availability: nil,
          realtime_availability: nil,
          consolidated_performance: nil,
          raw_fields: [],
          field_sources: Provider::Directa::FIELD_SOURCES
        ),
        positions: positions,
        unknown_message_types: []
      )
    end

    def position(code:, currency:, market:, phase:, instrument_type:, authorization:, quantity:, multiplier:, reference_price:)
      metadata = Provider::Directa::InstrumentMetadata.new(
        requested_code: code,
        canonical_code: code,
        isin: "US0378331005",
        currency: currency,
        description: "Synthetic instrument",
        directa_market: market,
        directa_segment: nil,
        multiplier: BigDecimal(multiplier),
        raw_multiplier: multiplier,
        price_codes: [],
        tick_table: nil,
        tick_size: nil,
        raw_tick_size: nil,
        identity_status: :partial,
        field_sources: Provider::Directa::FIELD_SOURCES,
        phase: phase,
        instrument_type: instrument_type,
        authorization_markets: [ authorization ],
        reference_price: BigDecimal(reference_price)
      )
      Provider::Directa::Position.new(
        univoco: code,
        quantity: quantity,
        raw_quantity: quantity.to_s,
        raw_average_price: "42.5",
        raw_fields: [],
        instrument_metadata: metadata
      )
    end
end
