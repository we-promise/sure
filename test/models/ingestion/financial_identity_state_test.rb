require "test_helper"

class Ingestion::FinancialIdentityStateTest < ActiveSupport::TestCase
  State = Ingestion::FinancialIdentityState

  test "an empty Transaction object and JSON null produce the same Ruby and database identity state" do
    entry = transaction_entry(extra: {})
    empty = assert_equivalent(entry)

    # The current column rejects SQL NULL. A retained JSONB null is read by Rails
    # as nil and exercises the production SQL's distinct JSON-null handling.
    Transaction.where(id: entry.entryable_id).update_all("extra = 'null'::jsonb")
    assert_nil entry.transaction.reload.extra
    missing = assert_equivalent(entry)

    assert_equal empty, missing
    assert_nil missing.fetch("pending_metadata").fetch("aliases")
    assert missing.fetch("pending_metadata").fetch("providers").values.all?(&:nil?)
  end

  test "Plaid pending links and exact retired aliases agree between Ruby snapshots and SQL" do
    entry = transaction_entry(source: "plaid", external_id: "booked", extra: {
      "plaid" => { "pending" => false, "pending_transaction_id" => "pending-current", "description" => "Unrelated description" },
      "auto_claimed_pending_ids" => [ "pending-z", "pending-a" ]
    })
    original = assert_equivalent(entry)
    assert_equal [ "pending-z", "pending-a" ], original.fetch("pending_metadata").fetch("aliases")
    assert_equal({ "pending" => false, "pending_transaction_id" => "pending-current" }, original.fetch("pending_metadata").fetch("providers").fetch("plaid"))

    entry.transaction.update!(extra: {
      "plaid" => { "pending" => true, "pending_transaction_id" => "pending-replaced" },
      "auto_claimed_pending_ids" => [ "pending-z" ]
    })
    changed = assert_equivalent(entry)
    assert_not_equal original, changed
    assert_equal({ "pending" => true, "pending_transaction_id" => "pending-replaced" }, changed.fetch("pending_metadata").fetch("providers").fetch("plaid"))
  end

  test "a false JSON scalar is preserved as malformed metadata instead of being treated as absent" do
    entry = transaction_entry(extra: {})
    empty = assert_equivalent(entry)
    Transaction.where(id: entry.entryable_id).update_all("extra = 'false'::jsonb")
    assert_equal false, entry.transaction.reload.extra

    scalar = assert_equivalent(entry)

    assert_equal false, scalar.fetch("pending_metadata")
    assert_not_equal empty, scalar
  end

  test "a plaid_id-only legacy Entry retains its nil source and external ID in both projections" do
    entry = transaction_entry(source: nil, external_id: nil, plaid_id: "legacy-id",
      extra: { "plaid" => { "pending" => false, "pending_transaction_id" => "legacy-pending" } })

    state = assert_equivalent(entry)

    assert_nil state.fetch("source")
    assert_nil state.fetch("external_id")
    assert_equal "legacy-id", state.fetch("plaid_id")
    assert_equal "legacy-pending", state.fetch("pending_metadata").fetch("providers").fetch("plaid").fetch("pending_transaction_id")
  end

  test "Sophtron own metadata is captured even though it is outside the common pending provider list" do
    refute_includes Transaction::PENDING_PROVIDERS, "sophtron"
    entry = transaction_entry(source: "sophtron", external_id: "sophtron_owned",
      extra: { "sophtron" => { "pending" => false, "description" => "Not identity" } })
    original = assert_equivalent(entry)
    assert_equal({ "pending" => false }, original.fetch("pending_metadata").fetch("providers").fetch("sophtron"))

    entry.transaction.update!(extra: { "sophtron" => { "pending" => true, "description" => "Changed description" } })
    changed = assert_equivalent(entry)
    assert_not_equal original, changed
    assert_equal({ "pending" => true }, changed.fetch("pending_metadata").fetch("providers").fetch("sophtron"))
  end

  test "Trades have no Transaction pending metadata and ignore quantity price category and extra changes" do
    entry = accounts(:investment).entries.create!(source: "ibkr", external_id: "ibkr_trade_state", name: "Original trade", date: Date.current,
      amount: BigDecimal("12.3456"), currency: "USD", entryable: Trade.new(security: securities(:aapl), qty: BigDecimal("1"),
        price: BigDecimal("12.3456"), currency: "USD", extra: { "plaid" => { "pending" => true }, "auto_claimed_pending_ids" => [ "ignored" ] }))
    original = assert_equivalent(entry)
    assert_nil original.fetch("pending_metadata")

    entry.update!(name: "Edited trade", amount: BigDecimal("24.6912"), user_modified: true)
    entry.trade.update!(qty: BigDecimal("2"), price: BigDecimal("13"), category: categories(:food_and_drink), extra: { "note" => "Edited" })

    assert_equal original, assert_equivalent(entry)
  end

  test "ordinary Transaction edits and descriptive metadata do not change either identity projection" do
    entry = transaction_entry(extra: { "up" => { "pending" => false, "memo" => "Original" }, "private_note" => "Original" })
    original = assert_equivalent(entry)

    entry.update!(name: "User description", amount: BigDecimal("98.7654"), date: Date.current - 3,
      user_modified: true, import_locked: true, locked_attributes: { "name" => true })
    entry.transaction.update!(category: categories(:food_and_drink), extra: {
      "up" => { "pending" => false, "memo" => "Updated" }, "private_note" => "Updated", "exchange_rate" => "1.2345"
    })

    assert_equal original, assert_equivalent(entry)
  end

  test "changes to exact source and legacy identity columns change both projections" do
    entry = transaction_entry
    original = assert_equivalent(entry)
    entry.update!(external_id: "up_different")
    renamed = assert_equivalent(entry)
    assert_not_equal original, renamed
    assert_equal "up_different", renamed.fetch("external_id")

    entry.update!(source: "plaid", plaid_id: "retained-old-id")
    changed_source = assert_equivalent(entry)
    assert_not_equal renamed, changed_source
    assert_equal "plaid", changed_source.fetch("source")
    assert_equal "retained-old-id", changed_source.fetch("plaid_id")
  end

  private
    def transaction_entry(source: "up", external_id: "up_#{SecureRandom.uuid}", extra: {}, **attributes)
      accounts(:depository).entries.create!({ source: source, external_id: external_id, name: "Original transaction",
        date: Date.current, amount: BigDecimal("12.3456"), currency: "USD", entryable: Transaction.new(extra: extra) }.merge(attributes))
    end

    def assert_equivalent(entry)
      entry.reload
      snapshot = { "entry" => entry.attributes, "entryable" => entry.entryable.reload.attributes }
      expected = State.from_snapshot(snapshot)
      # These are the terminal relation's actual join aliases. The tested JSONB
      # expression comes directly from production; the test does not reproduce it.
      actual = Entry.where(id: entry.id)
        .joins("LEFT JOIN transactions bootstrap_transactions ON entries.entryable_type = 'Transaction' AND bootstrap_transactions.id = entries.entryable_id")
        .joins("LEFT JOIN trades bootstrap_trades ON entries.entryable_type = 'Trade' AND bootstrap_trades.id = entries.entryable_id")
        .pick(Arel.sql(State.sql))
      actual = JSON.parse(actual) if actual.is_a?(String)

      assert_equal expected, actual
      expected
    end
end
