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
end
