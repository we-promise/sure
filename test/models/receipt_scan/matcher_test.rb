require "test_helper"

class ReceiptScan::MatcherTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @date = Date.current - 5.days
    @total = BigDecimal("437.21")
    @scan = receipt_scans(:processing)
    @placeholder = add_entry(amount: 0, date: Date.current, extra: { "receipt" => { "status" => "processing" } })
    @scan.update!(linked_transaction: @placeholder.entryable)
  end

  test "skips cash" do
    assert_equal :skip, match(payment_method: "cash").kind
  end

  test "skips invoice" do
    assert_equal :skip, match(document_kind: "invoice").kind
  end

  test "skips currency mismatch" do
    assert_equal :skip, match(currency: "EUR").kind
  end

  test "skips non-positive total" do
    assert_equal :skip, match(total: BigDecimal("-5")).kind
  end

  test "single match within window" do
    bank = add_entry(date: @date + 2.days)

    result = match

    assert_equal :single, result.kind
    assert_equal [ bank ], result.entries
  end

  test "a transfer or card payment of the same amount is not the receipt's payment" do
    add_entry(date: @date + 1.day).entryable.update!(kind: "cc_payment")
    bank = add_entry(date: @date + 2.days)

    assert_equal [ bank ], match.entries
  end

  test "an entry the user excluded is not the receipt's payment" do
    add_entry(date: @date + 1.day).update!(excluded: true)

    assert_equal :none, match.kind
  end

  test "no match outside window" do
    add_entry(date: @date + 4.days)

    assert_equal :none, match.kind
  end

  test "matches a pending bank entry" do
    pending = add_entry(date: @date, extra: { "plaid" => { "pending" => true } })

    result = match

    assert_equal :single, result.kind
    assert_equal [ pending ], result.entries
  end

  test "ignores split parents and their children" do
    parent = add_entry(date: @date)
    parent.split!([ { name: "A", amount: @total - 10, category_id: nil }, { name: "B", amount: 10, category_id: nil } ])

    assert_equal :none, match.kind
  end

  test "ambiguous with two candidates" do
    first = add_entry(date: @date)
    second = add_entry(date: @date + 1.day)

    result = match

    assert_equal :ambiguous, result.kind
    assert_equal [ first, second ].to_set, result.entries.to_set
  end

  test "flags identical earlier receipt" do
    earlier = add_entry(date: @date, extra: { "receipt" => { "status" => "completed" } })

    result = match

    assert_equal :duplicate_receipt, result.kind
    assert_equal [ earlier ], result.entries
  end

  test "flags a re-upload of a receipt already merged into a later bank entry" do
    merged = add_entry(date: @date + 2.days, extra: { "receipt" => { "status" => "completed", "date" => @date.iso8601 } })

    result = match

    assert_equal :duplicate_receipt, result.kind
    assert_equal [ merged ], result.entries
  end

  test "flags a cash receipt uploaded twice" do
    earlier = add_entry(date: @date, extra: { "receipt" => { "status" => "completed", "date" => @date.iso8601 } })

    result = match(payment_method: "cash")

    assert_equal :duplicate_receipt, result.kind
    assert_equal [ earlier ], result.entries
  end

  private
    def match(**overrides)
      extraction = build_receipt_extraction(**{ total: @total, date: @date, line_items: [] }.merge(overrides))
      ReceiptScan::Matcher.new(@scan, extraction).result
    end

    def add_entry(amount: @total, date:, extra: {})
      Entry.create!(
        account: @account, name: "Card payment", date:, currency: "USD", amount:,
        entryable: Transaction.new(extra:)
      )
    end
end
