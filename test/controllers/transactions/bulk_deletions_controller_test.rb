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

  test "bulk delete refuses a plan-owned purchase" do
    account = @user.family.accounts.create!(
      name: "Plan Card", accountable: CreditCard.new, balance: 0,
      currency: "USD", owner: @user, status: "active"
    )
    purchase = account.entries.create!(
      date: Date.current, name: "Laptop", amount: 1200, currency: "USD",
      entryable: Transaction.new(kind: "standard", category: categories(:one))
    )
    RecurringTransaction::InstallmentPlan.new(
      family: @user.family, user: @user, entry: purchase,
      interest_rate: 12, term_months: 12,
      first_due_on: Date.current + 1.month,
      interest_category_id: categories(:food_and_drink).id
    ).call

    assert_no_difference [ "Transaction.count", "Entry.count" ] do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: { entry_ids: [ purchase.id ] }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.bulk_deletions.locked", count: 1), flash[:alert]
    assert purchase.reload.persisted?
  end

  test "bulk delete reports a mixed selection" do
    account = @user.family.accounts.create!(
      name: "Plan Card", accountable: CreditCard.new, balance: 0,
      currency: "USD", owner: @user, status: "active"
    )
    purchase = account.entries.create!(
      date: Date.current, name: "Laptop", amount: 1200, currency: "USD",
      entryable: Transaction.new(kind: "standard", category: categories(:one))
    )
    RecurringTransaction::InstallmentPlan.new(
      family: @user.family, user: @user, entry: purchase,
      interest_rate: 12, term_months: 12,
      first_due_on: Date.current + 1.month,
      interest_category_id: categories(:food_and_drink).id
    ).call
    other = account.entries.create!(
      date: Date.current, name: "Coffee", amount: 5, currency: "USD",
      entryable: Transaction.new(kind: "standard", category: categories(:one))
    )

    assert_difference [ "Transaction.count", "Entry.count" ], -1 do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: { entry_ids: [ purchase.id, other.id ] }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.bulk_deletions.partial", destroyed: 1, count: 1), flash[:alert]
    assert purchase.reload.persisted?
    assert_not Entry.exists?(other.id)
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
end
