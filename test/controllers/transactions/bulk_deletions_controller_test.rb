require "test_helper"

class Transactions::BulkDeletionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @entry = entries(:transaction)
  end

  test "bulk delete" do
    transactions = @user.family.entries.transactions
    delete_count = transactions.size

    assert_difference([ "Transaction.count", "Entry.count" ], -delete_count) do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: {
          entry_ids: transactions.pluck(:id)
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "#{delete_count} transactions deleted", flash[:notice]
  end

  test "bulk delete with rejected transfers" do
    entry = entries(:transaction)
    other_entry = entries(:transfer_out)

    # Create a rejected_transfer referencing the entry's transaction
    RejectedTransfer.create!(
      inflow_transaction: entry.entryable,
      outflow_transaction: other_entry.entryable
    )

    assert_difference "RejectedTransfer.count", -1 do
      assert_difference [ "Transaction.count", "Entry.count" ], -1 do
        post transactions_bulk_deletion_url, params: {
          bulk_delete: {
            entry_ids: [ entry.id ]
          }
        }
      end
    end

    assert_redirected_to transactions_url
    assert_equal "1 transaction deleted", flash[:notice]
  end

  test "bulk delete also removes linked bond lots" do
    bond_account = accounts(:bond)
    entry = bond_account.entries.create!(
      name: "Bond purchase",
      date: Date.current,
      amount: 1500,
      currency: bond_account.currency,
      entryable: Transaction.new(kind: :funds_movement)
    )
    lot = bond_account.bond.bond_lots.create!(
      purchased_on: Date.current,
      amount: 1500,
      term_months: 12,
      interest_rate: 5.0,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      entry: entry
    )

    assert_difference([ "Entry.count", "Transaction.count", "BondLot.count" ], -1) do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: {
          entry_ids: [ entry.id ]
        }
      }
    end

    assert_not BondLot.exists?(lot.id)
    assert_redirected_to transactions_url
  end

  test "bulk delete reports skipped entries when some deletions are blocked" do
    bond_account = accounts(:bond)

    deletable_entry = bond_account.entries.create!(
      name: "Deletable transaction",
      date: Date.current,
      amount: 150,
      currency: bond_account.currency,
      entryable: Transaction.new(kind: :funds_movement)
    )

    blocked_lot = BondLot.create!(
      bond: bond_account.bond,
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "other_bond",
      term_months: 12,
      interest_rate: 10,
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      auto_close_on_maturity: true,
      tax_strategy: "standard",
      tax_rate: 19
    )
    blocked_lot.create_purchase_entry!
    blocked_lot.settle_if_matured!(on: Date.new(2025, 2, 1))
    blocked_entry = blocked_lot.entry

    assert_difference([ "Entry.count", "Transaction.count" ], -1) do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: {
          entry_ids: [ deletable_entry.id, blocked_entry.id ]
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "1 transaction deleted 1 transaction could not be deleted", flash[:notice]
    assert_not Entry.exists?(deletable_entry.id)
    assert Entry.exists?(blocked_entry.id)
  end
end
