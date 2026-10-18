require "test_helper"

class DirectaItem::HistoryNormalizerTest < ActiveSupport::TestCase
  COVERAGE_START = Date.new(2026, 5, 1)
  COVERAGE_END = Date.new(2026, 5, 31)
  BANK_SCOPE = "a" * 64
  BUY_REFERENCE = "A0000000000001"
  SELL_REFERENCE = "B0000000000002"

  test "normalizes a EUR buy, sale, and nontrade statement row" do
    buy_date = Date.new(2026, 5, 3)
    sell_date = Date.new(2026, 5, 4)
    orders = [
      order(reference: BUY_REFERENCE, side: "C", event_date: buy_date, quantity: 3, average_price: 10.5),
      order(reference: SELL_REFERENCE, side: "V", event_date: sell_date, quantity: 2, average_price: 30)
    ]
    rows = [
      trade_row(date: buy_date, value_date: buy_date + 2, reference: BUY_REFERENCE, price: "10,50", currency: "EUR", quantity: "+3", gross: "-31,50", commission: "-0,25"),
      trade_row(date: sell_date, value_date: sell_date + 2, reference: SELL_REFERENCE, price: "30,00", currency: "EUR", quantity: "-2", gross: "+60,00", commission: "-0,50"),
      [ "05/05/2026", "06/05/2026", "Cash movement", "CASH-1", "", "", "", "-25,00", "" ]
    ]

    result = normalize(orders:, statements: { statement_key => statement(rows:) })
    buy, sale = result.activities

    assert_equal [ buy_date, sell_date ], result.activities.map(&:date)
    assert_equal [ BigDecimal("3"), BigDecimal("-2") ], result.activities.map(&:quantity)
    assert_equal [ BigDecimal("10.5"), BigDecimal("30") ], result.activities.map(&:price)
    assert_equal [ BigDecimal("31.75"), BigDecimal("-59.5") ], result.activities.map(&:amount)
    assert_equal [ BigDecimal("0.25"), BigDecimal("0.5") ], result.activities.map(&:fee)
    assert_equal [ "EUR", "EUR" ], result.activities.map(&:currency)
    assert_equal "Synthetic instrument", buy.name
    assert_equal "executed_order_day", buy.metadata.fetch("aggregation")
    assert_equal "-31.5", buy.metadata.fetch("gross_eur")
    assert_equal "0.25", buy.metadata.fetch("fee_eur")
    assert_equal true, buy.metadata.fetch("commission_reported")
    assert_equal [ "2026-05-05" ], buy.metadata.fetch("value_dates")
    assert_equal 1, result.cohorts.fetch(buy_date.iso8601).fetch(buy.fingerprint)
    assert_equal 1, buy.occurrence
    assert_match(/\Adirecta-history-v1:[0-9a-f]{64}\z/, buy.external_id)
    refute_includes buy.external_id, BUY_REFERENCE
    refute_includes result.inspect, BUY_REFERENCE
    refute_includes buy.inspect, "Synthetic instrument"
    refute_includes buy.metadata.to_s, BUY_REFERENCE
  end

  test "groups partial fills by order and day and uses bank EUR gross for unit price" do
    date = Date.new(2026, 5, 3)
    usd_order = order(reference: BUY_REFERENCE, side: "C", event_date: date, quantity: 2, currency: "USD", average_price: 17.305)
    usd_rows = [
      trade_row(date:, value_date: date + 2, reference: BUY_REFERENCE, price: "17,304", currency: "USD", quantity: "+1", gross: "-15,00", commission: "-0,25"),
      trade_row(date:, value_date: date + 2, reference: BUY_REFERENCE, price: "17,304", currency: "USD", quantity: "+1", gross: "-15,00", commission: "")
    ]
    usd = normalize(orders: [ usd_order ], statements: { statement_key => statement(rows: usd_rows) }).activities.sole

    assert_equal BigDecimal("2"), usd.quantity
    assert_equal BigDecimal("15"), usd.price
    assert_equal BigDecimal("30.25"), usd.amount
    assert_equal BigDecimal("0.25"), usd.fee
    assert_equal "USD", usd.metadata.fetch("quote_currency")
    assert_equal [ "17,304", "17,304" ], usd.metadata.fetch("original_prices")
    assert_equal 2, usd.metadata.fetch("fill_count")
    assert_equal false, usd.metadata.fetch("commission_reported")
    assert_equal 1, usd.metadata.fetch("commission_reported_fill_count")
    assert_equal "reported_statement_commission_only", usd.metadata.fetch("fee_scope")

    bond_order = order(
      reference: SELL_REFERENCE,
      side: "C",
      event_date: date,
      quantity: 398,
      average_price: 9.901005,
      name: "Synthetic percent quoted bond"
    )
    bond_row = trade_row(
      date:, value_date: date + 2, reference: SELL_REFERENCE, price: "9,901", currency: "EUR", quantity: "+398", gross: "-392,00", commission: ""
    )
    bond = normalize(orders: [ bond_order ], statements: { statement_key => statement(rows: [ bond_row ]) }).activities.sole

    assert_equal (BigDecimal("392") / BigDecimal("398")).round(10), bond.price
    assert_equal BigDecimal("392"), bond.amount
    assert_equal "9,901", bond.metadata.fetch("original_prices").sole
  end

  test "reconciles fills before the activity window but returns only covered dates" do
    coverage_start = Date.new(2026, 6, 1)
    coverage_end = Date.new(2026, 6, 30)
    placement_date = Date.new(2026, 5, 20)
    early_fill_date = Date.new(2026, 5, 28)
    event_date = Date.new(2026, 6, 3)
    order = order(
      reference: BUY_REFERENCE,
      side: "C",
      event_date:,
      placement_date:,
      quantity: 2,
      average_price: 10
    )
    statements = {
      Date.new(2026, 5, 31) => statement(
        requested_date: Date.new(2026, 5, 31),
        rows: [ trade_row(date: early_fill_date, value_date: early_fill_date + 2, reference: BUY_REFERENCE, price: "10,00", currency: "EUR", quantity: "+1", gross: "-10,00", commission: "") ]
      ),
      Date.new(2026, 6, 30) => statement(
        requested_date: Date.new(2026, 6, 30),
        rows: [ trade_row(date: event_date, value_date: event_date + 2, reference: BUY_REFERENCE, price: "10,00", currency: "EUR", quantity: "+1", gross: "-10,00", commission: "") ]
      )
    }

    result = normalize(orders: [ order ], statements:, coverage_start:, coverage_end:)

    assert_equal 1, result.activities.length
    assert_equal [ event_date ], result.activities.map(&:date)
    assert_equal BigDecimal("1"), result.activities.sole.quantity
  end

  test "returns an empty result without statements when there are no executed orders" do
    result = normalize(orders: [], statements: {})

    assert_empty result.activities
    assert_empty result.cohorts
  end

  test "keeps the scoped ID stable and changes the fingerprint when fees change" do
    date = Date.new(2026, 5, 3)
    order = order(reference: BUY_REFERENCE, side: "C", event_date: date, quantity: 1, average_price: 10)
    first = normalize(
      orders: [ order ],
      statements: { statement_key => statement(rows: [ trade_row(date:, value_date: date + 2, reference: BUY_REFERENCE, price: "10,00", currency: "EUR", quantity: "+1", gross: "-10,00", commission: "-0,50") ]) }
    ).activities.sole
    corrected = normalize(
      orders: [ order ],
      statements: { statement_key => statement(rows: [ trade_row(date:, value_date: date + 2, reference: BUY_REFERENCE, price: "10,00", currency: "EUR", quantity: "+1", gross: "-10,00", commission: "-0,75") ]) }
    ).activities.sole

    assert_equal first.external_id, corrected.external_id
    refute_equal first.fingerprint, corrected.fingerprint
    assert_equal BigDecimal("10.5"), first.amount
    assert_equal BigDecimal("10.75"), corrected.amount
  end

  test "rejects duplicate references, partial orders, unexpected trades, and foreign order dates" do
    date = Date.new(2026, 5, 3)
    base_order = order(reference: BUY_REFERENCE, side: "C", event_date: date, quantity: 2, average_price: 10)
    base_row = trade_row(date:, value_date: date + 2, reference: BUY_REFERENCE, price: "10,00", currency: "EUR", quantity: "+2", gross: "-20,00", commission: "")

    assert_history_error("history_incomplete") do
      normalize(orders: [ base_order, base_order ], statements: { statement_key => statement(rows: [ base_row ]) })
    end
    assert_history_error("history_incomplete") do
      normalize(
        orders: [ base_order ],
        statements: { statement_key => statement(rows: [ trade_row(date:, value_date: date + 2, reference: BUY_REFERENCE, price: "10,00", currency: "EUR", quantity: "+1", gross: "-10,00", commission: "") ]) }
      )
    end
    assert_history_error("history_incomplete") do
      normalize(
        orders: [ base_order ],
        statements: { statement_key => statement(rows: [ base_row, trade_row(date:, value_date: date + 2, reference: "Z0000000000009", price: "10,00", currency: "EUR", quantity: "+1", gross: "-10,00", commission: "") ]) }
      )
    end
    assert_history_error("history_incomplete") do
      foreign = order(reference: BUY_REFERENCE, side: "C", event_date: Date.new(2026, 6, 3), quantity: 1, average_price: 10)
      normalize(orders: [ foreign ], statements: { statement_key => statement(rows: [ base_row ]) })
    end
  end

  test "rejects malformed statements and unsupported order actions with safe errors" do
    date = Date.new(2026, 5, 3)
    order = order(reference: BUY_REFERENCE, side: "C", event_date: date, quantity: 1, average_price: 10)
    row = trade_row(date:, value_date: date + 2, reference: BUY_REFERENCE, price: "10,00", currency: "EUR", quantity: "+1", gross: "-10,00", commission: "")
    malformed = statement(rows: [ row ]).sub("quantita'", "quantita")

    assert_history_error("history_invalid_data") do
      normalize(orders: [ order ], statements: { statement_key => malformed })
    end
    assert_history_error("history_invalid_data") do
      invalid_utf8 = statement(rows: [ row ]).dup.force_encoding(Encoding::UTF_8)
      invalid_utf8 << "\xFF".dup.force_encoding(Encoding::UTF_8)
      normalize(orders: [ order ], statements: { statement_key => invalid_utf8 })
    end
    assert_history_error("history_unsupported_activity") do
      unsupported = order(reference: BUY_REFERENCE, side: "D", event_date: date, quantity: 1, average_price: 10)
      normalize(orders: [ unsupported ], statements: { statement_key => statement(rows: [ row ]) })
    end
    assert_history_error("history_invalid_data") do
      unbounded = order(reference: BUY_REFERENCE, side: "C", event_date: date, quantity: 1, average_price: 1e40)
      normalize(orders: [ unbounded ], statements: { statement_key => statement(rows: [ row ]) })
    end
    assert_history_error("history_unsupported_activity") do
      foreign_currency = order(reference: BUY_REFERENCE, side: "C", event_date: date, quantity: 1, average_price: 10, currency: "GBP")
      normalize(orders: [ foreign_currency ], statements: { statement_key => statement(rows: [ row ]) })
    end
  end

  private

    def normalize(orders:, statements:, coverage_start: COVERAGE_START, coverage_end: COVERAGE_END)
      DirectaItem::HistoryNormalizer.new(
        orders: orders,
        statements: statements,
        bank_scope: BANK_SCOPE,
        coverage_start: coverage_start,
        coverage_end: coverage_end
      ).normalize
    end

    def order(reference:, side:, event_date:, quantity:, average_price:, currency: "EUR", placement_date: event_date, name: "Synthetic instrument", state: "e ")
      {
        "Riferimento" => reference,
        "Stato" => state,
        "AcqVen" => side,
        "QuantitaOrdine" => quantity,
        "QuantitaEseguita" => quantity,
        "DataEvento" => event_date.strftime("%Y%m%d").to_i,
        "DataImmissione" => placement_date.strftime("%Y%m%d").to_i,
        "Isin" => "US0378331005",
        "Descrizione" => name,
        "Divisa" => currency,
        "PrezzoMedio" => average_price
      }
    end

    def trade_row(date:, value_date:, reference:, price:, currency:, quantity:, gross:, commission:)
      [ date.strftime("%d/%m/%Y"), value_date.strftime("%d/%m/%Y"), "Synthetic instrument", reference, price, currency, quantity, gross, commission ]
    end

    def statement_key
      COVERAGE_END
    end

    def statement(rows:, requested_date: statement_key)
      from_date = Date.new(requested_date.year, requested_date.month, 1)
      CSV.generate(col_sep: ";", row_sep: "\r\n") do |csv|
        csv << [ "Synthetic account owner", "18/10/2026", "13:05:29" ]
        csv << [ "Estratto Conto   dal", from_date.strftime("%-d/%m/%Y"), "al", requested_date.strftime("%-d/%m/%Y") ]
        csv << DirectaItem::HistoryNormalizer::CSV_HEADER
        rows.each { |row| csv << row }
      end.encode(Encoding::ISO_8859_1).b
    end

    def assert_history_error(expected_code)
      error = assert_raises(DirectaItem::PortfolioNormalizer::Error) { yield }
      assert_equal expected_code, error.code
      refute_match(/#{Regexp.escape(BUY_REFERENCE)}|#{Regexp.escape(SELL_REFERENCE)}|#{BANK_SCOPE}/, error.message)
    end
end
