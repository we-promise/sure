require "test_helper"

class FinecoItem::HistoryNormalizerTest < ActiveSupport::TestCase
  test "normalizes bank-local timestamps independently of the process time zone" do
    prior_zone = Time.zone
    Time.zone = "America/Los_Angeles"

    activity = normalize([ row("transactionDate" => "2026-10-17T12:34:56", "valueDate" => "2026-10-19T00:00:00") ]).activities.sole

    assert_equal Date.new(2026, 10, 17), activity.date
    assert_equal "2026-10-17T12:34:56.000000+02:00", activity.metadata.fetch("transaction_timestamp")
    assert_equal "2026-10-19", activity.metadata.fetch("value_date")
  ensure
    Time.zone = prior_zone
  end

  test "normalizes valid Z and offset timestamps to the Fineco bank time zone" do
    activity = normalize(
      [ row("transactionDate" => "2026-10-17T23:00:00Z", "valueDate" => "2026-10-17T23:00:00+00:00") ]
    ).activities.sole

    assert_equal Date.new(2026, 10, 18), activity.date
    assert_equal "2026-10-18T01:00:00.000000+02:00", activity.metadata.fetch("transaction_timestamp")
    assert_equal "2026-10-18", activity.metadata.fetch("value_date")
  end

  test "keeps duplicate trade occurrences while expressing the EUR gross as unit price" do
    bond = row(
      "isin" => "US0000000010",
      "name" => "Synthetic bond",
      "currency" => "GBP",
      "price" => "98.5",
      "amount" => "2",
      "exchange" => "1.25",
      "equivalentValue" => "246.25"
    )
    result = normalize([ bond, bond ])

    assert_equal [ 1, 2 ], result.activities.map(&:occurrence)
    assert_equal 2, result.activities.map(&:external_id).uniq.size
    assert_equal BigDecimal("123.125"), result.activities.first.price
    assert_equal BigDecimal("246.25"), result.activities.first.amount
    assert_equal "EUR", result.activities.first.currency
    assert_equal "GBP", result.activities.first.metadata.fetch("original_currency")
    assert_equal({ "2026-10-17" => { result.activities.first.fingerprint => 2 } }, result.cohorts)
  end

  test "accepts a complete empty window and redacts source descriptions from inspection" do
    result = normalize([])

    assert_empty result.activities
    assert_empty result.cohorts
    refute_includes normalize([ row("name" => "private source description") ]).inspect, "private source description"
    refute_includes normalize([ row("name" => "private source description") ]).activities.first.inspect, "private source description"
  end

  test "rejects unsupported signs and malformed dates" do
    assert_equal "history_unsupported_activity", import_error(row("sign" => "D")).code
    assert_equal "history_invalid_data", import_error(row("transactionDate" => "2026-02-30T12:00:00")).code

    [
      "2026-02-30T12:00:00+01:00",
      "2026-10-17T24:00:00+01:00",
      "2026-10-17T12:00:60+01:00",
      "2026-10-17T12:00:00.1234567+01:00",
      "2026-10-17T12:00:00+01:60"
    ].each do |timestamp|
      assert_equal "history_invalid_data", import_error(row("transactionDate" => timestamp)).code
    end
  end

  private

    def normalize(rows)
      FinecoItem::HistoryNormalizer.new(rows: rows, bank_scope: "synthetic-bank-scope").normalize
    end

    def import_error(row)
      assert_raises(FinecoItem::PortfolioImportError) { normalize([ row ]) }
    end

    def row(overrides = {})
      {
        "type" => "ORDER",
        "transactionDate" => "2026-10-17T12:34:56",
        "valueDate" => "2026-10-19T00:00:00",
        "description" => "Synthetic activity",
        "name" => "Synthetic activity",
        "isin" => "US0000000002",
        "sign" => "A",
        "amount" => "3",
        "currency" => "EUR",
        "price" => "100",
        "exchange" => "1",
        "equivalentValue" => "300"
      }.merge(overrides)
    end
end
