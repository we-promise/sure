require "test_helper"

# The statement generation's merge and its answer-free checks, on the spike's
# BAC sample: one page, an OCR'd text layer with errors, 13 transactions.
class Ai::Generations::ExtractBankStatementTest < ActiveSupport::TestCase
  BAC_ROWS = [
    [ "2019-02-01", -24.5 ], [ "2019-02-01", -20.0 ], [ "2019-02-03", -30.0 ], [ "2019-02-04", 2575.0 ], [ "2019-02-11", 300.0 ],
    [ "2019-02-16", -50.0 ], [ "2019-02-17", -40.0 ], [ "2019-02-17", -78.34 ], [ "2019-02-18", 2575.0 ], [ "2019-02-18", -15.0 ],
    [ "2019-02-24", -150.0 ], [ "2019-02-24", 25.0 ], [ "2019-02-28", -987.33 ]
  ].freeze

  setup do
    @source = Pdf::TextExtractor.pages(file_fixture("statements/bac_ocr.pdf").binread).join("\n")
  end

  test "a right extraction passes every check" do
    checks = check(value(BAC_ROWS))

    assert checks.reconciles
    assert checks.amounts_in_source
    assert_operator checks.dates_anchored, :>=, 0.5
    assert checks.passed?
    assert_equal true, checks.to_h[:passed]
  end

  test "a flipped sign, a missing row or a merged row fails reconciles" do
    flipped = BAC_ROWS.map { |date, amount| amount == -78.34 ? [ date, 78.34 ] : [ date, amount ] }
    missing = BAC_ROWS - [ [ "2019-02-11", 300.0 ] ]

    assert_not check(value(flipped)).reconciles
    assert_not check(value(missing)).passed?
  end

  test "every amount right but the dates wrong fails dates_anchored, which reconciling can't see" do
    shifted = BAC_ROWS.map { |date, amount| [ (Date.parse(date) + 9).iso8601, amount ] }

    checks = check(value(shifted))
    assert checks.reconciles
    assert_operator checks.dates_anchored, :<, 0.5
    assert_not checks.passed?
  end

  test "an amount the text doesn't hold fails amounts_in_source; images have no source to check" do
    invented = BAC_ROWS + [ [ "2019-02-20", -12.34 ], [ "2019-02-21", 12.34 ] ]

    assert_equal false, check(value(invented)).amounts_in_source
    assert_nil check(value(BAC_ROWS), source: nil).amounts_in_source
    assert check(value(BAC_ROWS), source: nil).passed?, "only reconciles applies to images"
  end

  test "the text's printed balances win over the model's" do
    checks = Ai::Generations::ExtractBankStatement.checks(value(BAC_ROWS).merge(closing_balance: 1.0), source: @source,
                                                         balances: { opening_balance: 40_000.0, closing_balance: 44_079.83 })
    assert checks.reconciles
  end

  test "a printed opening and a printed closing balance are used independently" do
    printed_opening = value(BAC_ROWS).merge(opening_balance: 1.0, closing_balance: 44_079.83)
    printed_closing = value(BAC_ROWS).merge(opening_balance: 40_000.0, closing_balance: 2.0)

    assert Ai::Generations::ExtractBankStatement.checks(printed_opening, source: @source,
                                                        balances: { opening_balance: 40_000.0 }).reconciles
    assert Ai::Generations::ExtractBankStatement.checks(printed_closing, source: @source,
                                                        balances: { closing_balance: 44_079.83 }).reconciles
  end

  test "an invalid transaction date fails the check, with or without text to anchor against" do
    extraction = value([ [ "2019-02-01", -24.5 ] ])
    extraction[:transactions] << row("not a date", -20.0)

    assert_equal 0.0, check(extraction).dates_anchored
    assert check(extraction).worth_another_way?
    assert_equal 0.0, check(extraction, source: nil).dates_anchored
  end

  test "a row the model gave no date or a non-numeric amount stays in the extraction and fails the checks" do
    generation = Ai::Generations::ExtractBankStatement.new(units: [], content: "", family: nil)
    answer = { "opening_balance" => 100, "closing_balance" => 110, "transactions" => [
      { "date" => "2019-02-01", "description" => "Fee", "amount" => 10 },
      { "date" => "", "description" => "In", "amount" => 20 }, { "date" => nil, "description" => "Out", "amount" => -20 },
      { "date" => "2019-02-02", "description" => "Grouped", "amount" => "1,234.56" }
    ] }
    value = generation.coerce(answer)

    assert_equal 4, value[:transactions].size
    checks = Ai::Generations::ExtractBankStatement.checks(value, source: nil)
    assert_equal false, checks.reconciles
    assert_equal 0.0, checks.dates_anchored
    assert_equal 4, Ai::Generations::ExtractBankStatement.statement(value)[:transactions].size
  end

  test "a date without a year uses the statement period's year" do
    extraction = value([ [ "1/2", -24.5 ] ])   # 1 February, as a batch that doesn't print the year

    checks = Ai::Generations::ExtractBankStatement.checks(extraction, source: "01/02 Rent 24.50")
    assert_operator checks.dates_anchored, :>=, 0.5
    assert_nil check(extraction, source: nil).dates_anchored, "nothing to anchor a yearless date against"

    statement = Ai::Generations::ExtractBankStatement.statement(extraction)
    assert_equal "2019-02-01", statement[:transactions].sole[:date]
  end

  test "a yearless date in a December-to-January period resolves to the closing year" do
    extraction = value([ [ "1/1", -24.5 ] ])   # 1 January, printed without a year
    extraction[:statement_period] = { start_date: "2019-12-01", end_date: "2020-01-31" }

    statement = Ai::Generations::ExtractBankStatement.statement(extraction)
    assert_equal "2020-01-01", statement[:transactions].sole[:date]

    # An ambiguous date the period can't place is left unresolved, not guessed.
    ambiguous = value([ [ "1/6", -24.5 ] ])   # 1 June, which fits both years of a two-year period
    ambiguous[:statement_period] = { start_date: "2019-01-01", end_date: "2020-12-31" }
    assert_nil Ai::Generations::ExtractBankStatement.statement(ambiguous)[:transactions].sole[:date]
  end

  test "without balances, reconciles can't tell: flagged, with nothing another way could fix" do
    checks = check(value(BAC_ROWS).merge(opening_balance: nil, closing_balance: nil))

    assert_nil checks.reconciles
    assert_equal [ :balances ], checks.failed
    assert_not checks.passed?
    assert_not checks.worth_another_way?
    assert_equal true, checks.to_h[:settled], "stored, so Auto learns from it"
    assert check(value(BAC_ROWS.drop(1))).worth_another_way?, "a balance that doesn't reconcile is worth another way"
  end

  test "batches merge in order, dropping a row repeated at a boundary but not within a batch" do
    generation = Ai::Generations::ExtractBankStatement.new(units: [], content: "", family: families(:dylan_family))
    first = { bank_name: "YourBank", opening_balance: 40_000.0, closing_balance: 41_000.0, statement_period: { start_date: "2019-02-01", end_date: nil },
              transactions: [ row("2019-02-01", -5.0), row("2019-02-01", -5.0), row("2019-02-10", -20.0) ] }
    second = { bank_name: nil, opening_balance: nil, closing_balance: 44_079.83, statement_period: { start_date: nil, end_date: "2019-03-01" },
               transactions: [ row("2019-02-10", -20.0), row("2019-02-20", 30.0) ] }

    merged = generation.merge_values([ first, second ])

    assert_equal [ -5.0, -5.0, -20.0, 30.0 ], merged[:transactions].map { _1[:amount] }
    assert_equal "YourBank", merged[:bank_name]
    assert_equal [ 40_000.0, 44_079.83 ], merged.values_at(:opening_balance, :closing_balance)
    assert_equal({ start_date: "2019-02-01", end_date: "2019-03-01" }, merged[:statement_period])
  end

  test "statement gives today's extracted_data shape" do
    statement = Ai::Generations::ExtractBankStatement.statement(value([ [ "2019-02-01", -24.5 ] ]))

    assert_equal [ { date: "2019-02-01", amount: -24.5, name: "row", category: nil, notes: nil } ], statement[:transactions]
    assert_equal({ start_date: "2019-02-01", end_date: "2019-03-01" }, statement[:period])
    assert_equal 40_000.0, statement[:opening_balance]
  end

  test "a date form inside a longer printed day doesn't anchor a different row" do
    extraction = value([ [ "2019-02-01", -5.0 ], [ "2019-02-11", 300.0 ] ])

    checks = Ai::Generations::ExtractBankStatement.checks(
      extraction, source: "1february Rent 5.00 11february Deposit 300.00"
    )

    assert_equal 1.0, checks.dates_anchored
  end

  test "an amount inside a longer printed number isn't in the source" do
    checks = Ai::Generations::ExtractBankStatement.checks(
      { opening_balance: 100.0, closing_balance: 120.0, transactions: [ { date: "2019-02-01", amount: 20.0 } ] },
      source: "01/02 Rent 120.00 Refund -100.00"
    )

    assert_equal false, checks.amounts_in_source
  end

  test "only a row repeated across a batch boundary is dropped; equal rows inside a batch are two purchases" do
    coffee = { date: "2019-02-01", description: "Coffee", amount: -12.5, reference: nil, category: nil }
    lunch = { date: "2019-02-01", description: "Lunch", amount: -9.0, reference: nil, category: nil }
    generation = Ai::Generations::ExtractBankStatement.new(units: [], content: "", family: nil)

    merged = generation.merge_values([ { transactions: [ lunch, coffee ] }, { transactions: [ coffee, coffee, lunch ] } ])

    assert_equal [ lunch, coffee, coffee, lunch ], merged[:transactions]
  end

  test "batches with no transactions still supply the opening and closing balances" do
    generation = Ai::Generations::ExtractBankStatement.new(units: [], content: "", family: nil)
    first = { opening_balance: 40_000.0, statement_period: { start_date: "2019-02-01" }, transactions: [] }
    middle = { transactions: [ row("2019-02-04", -5.0) ] }
    last = { closing_balance: 44_079.83, statement_period: { end_date: "2019-03-01" }, transactions: [] }

    merged = generation.merge_values([ first, middle, last ])

    assert_equal [ -5.0 ], merged[:transactions].map { _1[:amount] }
    assert_equal [ 40_000.0, 44_079.83 ], merged.values_at(:opening_balance, :closing_balance)
    assert_equal({ start_date: "2019-02-01", end_date: "2019-03-01" }, merged[:statement_period])
  end

  test "split pages merge in document order when a fallback recovers an earlier page" do
    use_ai_routes(extract_pdf: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    use_ai_model_settings("openai/gpt-4.1-mini", batch_size: 1)
    units = [ Ai::PdfReading::Unit.text("PAGE ONE", page: 1), Ai::PdfReading::Unit.text("PAGE TWO", page: 2) ]
    page = lambda do |number|
      value(number == 1 ? [ [ "2019-02-01", -5.0 ] ] : [ [ "2019-02-01", -5.0 ], [ "2019-02-04", 30.0 ] ])
            .merge(opening_balance: number == 1 ? 40_000.0 : 41_000.0,
                   closing_balance: number == 1 ? 41_000.0 : 44_079.83)
    end
    stub_ai(:extract_pdf) do |request|
      number = request.input.include?("PAGE ONE") ? 1 : 2
      if request.model.endpoint.name == "gpu"
        raise Ai::Error::ContextTooLong, "too long" if request.input.include?("PAGE TWO") && number == 1
        raise Ai::Error::InvalidOutput, "garbage" if number == 1
      end
      page.(number)
    end

    result = Ai::Generations::ExtractBankStatement.new(units:, content: "", family: families(:dylan_family)).call

    assert result.success?
    assert_equal [ -5.0, 30.0 ], result.value[:transactions].map { _1[:amount] }, "the cut row is still deduped at the boundary"
    assert_equal [ 40_000.0, 44_079.83 ], result.value.values_at(:opening_balance, :closing_balance)
  end

  test "an extraction missing pages is incomplete: worth another way, and flagged" do
    checks = check(value(BAC_ROWS)).with(complete: false)

    assert_not checks.passed?
    assert checks.worth_another_way?
    assert_includes checks.failed, :complete
  end

  private
    def row(date, amount) = { date:, description: "row", amount:, reference: nil, category: nil }

    def value(rows)
      { bank_name: "YourBank", opening_balance: 40_000.0, closing_balance: 44_079.83,
        statement_period: { start_date: "2019-02-01", end_date: "2019-03-01" },
        transactions: rows.map { |date, amount| row(date, amount) } }
    end

    def check(value, source: @source) = Ai::Generations::ExtractBankStatement.checks(value, source:)
end
