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

  test "bulk delete of an outflow also removes its fabricated transfer counterpart" do
    accounts(:loan).update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN
    outflow_entry = accounts(:depository).entries.create!(
      name: "Loan payment", amount: 500, currency: "USD", date: Date.current,
      entryable: Transaction.new(counterparty_iban: "DE89370400440532013000") # pipelock:ignore IBAN
    )
    @user.family.auto_create_missing_transfer_counterparts!
    fabricated_entry = Transfer.find_by!(outflow_transaction_id: outflow_entry.entryable_id).inflow_transaction.entry

    post transactions_bulk_deletion_url, params: { bulk_delete: { entry_ids: [ outflow_entry.id ] } }

    assert_redirected_to transactions_url
    assert_not Entry.exists?(fabricated_entry.id)
  end

  test "bulk delete of an outflow and its fabricated transfer counterpart together" do
    accounts(:loan).update!(iban: "DE89370400440532013000") # pipelock:ignore IBAN
    outflow_entry = accounts(:depository).entries.create!(
      name: "Loan payment", amount: 500, currency: "USD", date: Date.current,
      entryable: Transaction.new(counterparty_iban: "DE89370400440532013000") # pipelock:ignore IBAN
    )
    @user.family.auto_create_missing_transfer_counterparts!
    fabricated_entry = Transfer.find_by!(outflow_transaction_id: outflow_entry.entryable_id).inflow_transaction.entry

    assert_difference [ "Transaction.count", "Entry.count" ], -2 do
      post transactions_bulk_deletion_url, params: {
        bulk_delete: { entry_ids: [ outflow_entry.id, fabricated_entry.id ] }
      }
    end

    assert_redirected_to transactions_url
    assert_not Transfer.exists?(outflow_transaction_id: outflow_entry.entryable_id)
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
