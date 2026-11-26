require "test_helper"

class Purchase::MatcherTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @ordered_on = Date.current - 10.days
    @purchase = purchases(:allegro_awaiting)
    @purchase.update!(ordered_on: @ordered_on, total: BigDecimal("249.99"), currency: "USD")
  end

  test "single candidate within the window" do
    entry = payment(date: @ordered_on + 2.days)

    result = match

    assert_equal :single, result.kind
    assert_equal [ entry ], result.entries
  end

  test "day four is outside the card window but inside the cash-on-delivery window" do
    entry = payment(date: @ordered_on + 4.days)
    assert_equal :none, match.kind

    @purchase.update!(payment_method: :cash_on_delivery)
    assert_equal [ entry ], match.entries
  end

  test "an entry dated before the order is not a candidate" do
    payment(date: @ordered_on - 1.day)

    assert_equal :none, match.kind
  end

  test "an account shared read-only with the user is not searched" do
    @purchase.update!(user: users(:family_member))
    payment(date: @ordered_on, account: accounts(:credit_card))

    assert_equal :none, match.kind
  end

  test "an account shared with full control is searched" do
    @purchase.update!(user: users(:family_member))
    entry = payment(date: @ordered_on)

    assert_equal [ entry ], match.entries
  end

  test "pending entries are not candidates" do
    payment(date: @ordered_on, extra: { "plaid" => { "pending" => true } })

    assert_equal :none, match.kind
  end

  test "transfers are not candidates" do
    payment(date: @ordered_on, kind: "funds_movement")

    assert_equal :none, match.kind
  end

  test "an entry already linked to another purchase is not a candidate" do
    entry = payment(date: @ordered_on)
    purchases(:allegro_matched).update!(linked_transaction: entry.entryable)

    assert_equal :none, match.kind
  end

  test "a receipt placeholder still processing is not a candidate" do
    payment(date: @ordered_on, extra: { "receipt" => { "status" => "processing" } })

    assert_equal :none, match.kind
  end

  test "an entry the user unlinked before is not offered again" do
    entry = payment(date: @ordered_on)
    @purchase.update!(rejected_entry_ids: [ entry.id ])

    assert_equal :none, match.kind
  end

  test "a different currency is not a candidate" do
    payment(date: @ordered_on, currency: "EUR")

    assert_equal :none, match.kind
  end

  test "split children are not candidates" do
    parent = payment(date: @ordered_on, amount: 300)
    parent.split!([ { name: "A", amount: BigDecimal("249.99"), category_id: nil }, { name: "B", amount: BigDecimal("50.01"), category_id: nil } ])

    assert_equal :none, match.kind
  end

  test "two candidates are ambiguous" do
    first = payment(date: @ordered_on)
    second = payment(date: @ordered_on + 1.day)

    result = match

    assert_equal :ambiguous, result.kind
    assert_equal [ first, second ], result.entries
  end

  test "installments are skipped" do
    payment(date: @ordered_on)
    @purchase.update!(payment_method: :installments)

    assert_equal :skipped, match.kind
  end

  test "a purchase without a total or date is skipped" do
    @purchase.update!(total: nil)
    assert_equal :skipped, match.kind

    @purchase.update!(total: 10, ordered_on: nil)
    assert_equal :skipped, match.kind
  end

  test "linking one of two identical orders removes the entry from the other's candidates" do
    first = payment(date: @ordered_on)
    second = payment(date: @ordered_on)
    other = Purchase.create!(family: @purchase.family, user: @purchase.user, source: :email, status: :awaiting_payment,
                             merchant: "Allegro", order_number: "A-2002", ordered_on: @ordered_on, total: @purchase.total, currency: "USD")

    assert_equal :ambiguous, @purchase.apply_match!
    assert_equal :ambiguous, other.apply_match!

    @purchase.link!(first, manual: true)

    assert_equal [ second ], Purchase::Matcher.new(other).result.entries
  end

  private
    def match
      Purchase::Matcher.new(@purchase).result
    end

    def payment(date:, amount: BigDecimal("249.99"), currency: "USD", account: accounts(:depository), extra: {}, kind: nil)
      attributes = { account:, date:, amount:, currency:, name: "Allegro" }
      attributes[:kind] = kind if kind
      entry = create_transaction(attributes)
      entry.entryable.update!(extra:) if extra.present?
      entry
    end
end
