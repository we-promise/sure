require "test_helper"

class Transaction::RefundablePurchasesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @purchase = create_transaction(account: @account, amount: 1000, name: "Original purchase")
  end

  test "keeps posted standard outflows and drops every ineligible row" do
    credit = create_transaction(account: @account, amount: -500, name: "Credit")
    refund = create_transaction(account: @account, amount: -200, name: "Refund")
    refund.transaction.mark_as_refund!
    transfer_out = create_transaction(account: @account, amount: 300, name: "Transfer out")
    transfer_in = create_transaction(account: accounts(:credit_card), amount: -300, name: "Transfer in")
    Transfer.create!(
      inflow_transaction: transfer_in.transaction,
      outflow_transaction: transfer_out.transaction,
      status: "confirmed"
    )
    pending = create_transaction(account: @account, amount: 400, name: "Pending")
    pending.transaction.update!(extra: { plaid: { pending: true } })
    excluded = create_transaction(account: @account, amount: 500, name: "Excluded", excluded: true)
    split_parent = create_transaction(account: @account, amount: 600, name: "Split parent")
    create_transaction(account: @account, amount: 600, name: "Split child", parent_entry_id: split_parent.id)

    results = query(Entry.where(id: [
      @purchase.id, credit.id, refund.id, transfer_out.id, transfer_in.id,
      pending.id, excluded.id, split_parent.id
    ]))

    assert_equal [ @purchase ], results
  end

  test "searches by entry name" do
    matching = create_transaction(account: @account, amount: 100, name: "Zebra return purchase")
    other = create_transaction(account: @account, amount: 100, name: "Other purchase")

    results = query(Entry.where(id: [ matching.id, other.id ]), search: "zebra")

    assert_equal [ matching ], results
  end

  test "ignores non-string searches instead of raising" do
    results = query(Entry.where(id: [ @purchase.id ]), search: { name: "Original" })

    assert_equal [ @purchase ], results
  end

  test "orders newest first and honours the limit" do
    older = create_transaction(account: @account, amount: 100, name: "Older", date: 2.days.ago.to_date)
    newer = create_transaction(account: @account, amount: 100, name: "Newer", date: Date.current)
    entries = Entry.where(id: [ older.id, newer.id ])

    assert_equal [ newer, older ], query(entries)

    assert_equal [ newer ], query(entries, limit: 1)
  end

  private
    def query(entries, search: nil, limit: nil)
      Transaction::RefundablePurchases.new(entries: entries, search: search, limit: limit).call
    end
end
