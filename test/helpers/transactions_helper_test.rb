require "test_helper"
require "ostruct"

class TransactionsHelperTest < ActionView::TestCase
  # build_transaction_extra_details reads `extra` off a Transaction (or anything
  # that responds to :transaction), so a struct is enough to drive it.
  def transaction_with(extra)
    OpenStruct.new(extra: extra)
  end

  test "extracts the named Plaid fields into their own section" do
    details = build_transaction_extra_details(transaction_with({
      "plaid" => {
        "pending" => false,
        "original_description" => "AMZN Mktp US*AB12CD SEATTLE WA",
        "payment_channel" => "online",
        "transaction_code" => "purchase"
      }
    }))

    assert_equal :plaid, details[:kind]
    assert_equal "AMZN Mktp US*AB12CD SEATTLE WA", details[:plaid][:original_description]
    assert_equal "online", details[:plaid][:payment_channel]
    assert_equal "purchase", details[:plaid][:transaction_code]
  end

  test "flattens payment_meta and counterparties into labeled rows" do
    details = build_transaction_extra_details(transaction_with({
      "plaid" => {
        "payment_meta" => { "reference_number" => "REF-1" },
        "counterparties" => [ { "name" => "Amazon", "type" => "merchant" } ]
      }
    }))

    rows = details[:provider_extras].index_by { |row| row[:key] }

    assert_equal "REF-1", rows["Payment meta · Reference number"][:value]
    assert_equal "Amazon", rows["Counterparty 1 · Name"][:value]
    assert_equal "merchant", rows["Counterparty 1 · Type"][:value]
    refute rows["Counterparty 1 · Name"][:multiline]
  end

  # A composed label is part translation, part provider identifier. Running
  # `humanize` over the whole thing lowercased the translated half, so the field
  # name is translated on its own and the result is left alone.
  test "labels a provider field we do not know by humanizing its identifier" do
    details = build_transaction_extra_details(transaction_with({
      "plaid" => { "payment_meta" => { "some_future_field" => "value" } }
    }))

    keys = details[:provider_extras].map { |row| row[:key] }

    assert_includes keys, "Payment meta · Some future field"
  end

  # The drawer should stay closed for transactions where Plaid told us nothing
  # beyond reconciliation flags the pending badge already shows.
  test "returns nil when the Plaid extra holds only pending flags" do
    details = build_transaction_extra_details(transaction_with({
      "plaid" => { "pending" => true, "pending_transaction_id" => "txn_1" }
    }))

    assert_nil details
  end

  # SimpleFIN writes a pending flag on every transaction, so this is the common
  # case rather than an edge one: without the guard the section opens empty.
  test "returns nil when the SimpleFIN extra holds only a pending flag" do
    details = build_transaction_extra_details(transaction_with({
      "simplefin" => { "pending" => false }
    }))

    assert_nil details
  end

  test "still returns SimpleFIN details when the provider sent something to show" do
    details = build_transaction_extra_details(transaction_with({
      "simplefin" => { "pending" => false, "payee" => "Whole Foods" }
    }))

    assert_equal :simplefin, details[:kind]
    assert_equal "Whole Foods", details[:simplefin][:payee]
  end

  # Regression: the array branch used to hand provider_extra_row an
  # already-encoded string, which then got encoded a second time and rendered as
  # an escaped one-liner ("[\n  {\"a\": 1}\n]") instead of a formatted block.
  test "renders an array of hashes as formatted JSON, encoded once" do
    details = build_transaction_extra_details(transaction_with({
      "plaid" => {
        "payment_meta" => { "parties" => [ { "name" => "Amazon" } ] }
      }
    }))

    row = details[:provider_extras].first

    assert row[:multiline]
    assert_equal [ { "name" => "Amazon" } ], JSON.parse(row[:value])
    assert_includes row[:value], "\n"
    refute_includes row[:value], "\\\""
  end

  test "falls back to a raw JSON dump for providers with no structured rendering" do
    details = build_transaction_extra_details(transaction_with({ "someprovider" => { "a" => 1 } }))

    assert_equal :raw, details[:kind]
    assert_empty details[:provider_extras]
    assert_equal({ "someprovider" => { "a" => 1 } }, JSON.parse(details[:raw]))
  end
end
