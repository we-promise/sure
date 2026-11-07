require "test_helper"

# The statement generation's merge and its answer-free checks (2e plan, step 6), on the spike's
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

  private
    def row(date, amount) = { date:, description: "row", amount:, reference: nil, category: nil }

    def value(rows)
      { bank_name: "YourBank", opening_balance: 40_000.0, closing_balance: 44_079.83,
        statement_period: { start_date: "2019-02-01", end_date: "2019-03-01" },
        transactions: rows.map { |date, amount| row(date, amount) } }
    end

    def check(value, source: @source) = Ai::Generations::ExtractBankStatement.checks(value, source:)
end
