require "test_helper"

class Transactions::BulkDeletionsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

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

  test "bulk delete keeps a split whose part is linked as a transfer and deletes the rest" do
    parent = create_transaction(account: accounts(:depository), amount: 100, name: "Mortgage")
    part = parent.split!([ { name: "Principal", amount: 60 }, { name: "Interest", amount: 40 } ]).first
    transfer = link_split_part_to_loan(part)

    post transactions_bulk_deletion_url, params: { bulk_delete: { entry_ids: [ parent.id, @entry.id ] } }

    assert Entry.exists?(parent.id)
    assert Transfer.exists?(transfer.id)
    assert_not Entry.exists?(@entry.id)
    assert_equal "1 transaction deleted", flash[:notice]
    assert_equal I18n.t("transactions.bulk_deletions.create.part_transferred", count: 1), flash[:alert]
  end

  test "bulk delete keeps a vest's income and taxes and deletes the rest" do
    form = Trade::VestForm.new(account: accounts(:investment), date: Date.current, manual_ticker: "AAPL", vested_qty: 100, units_withheld: 30, price: 10)
    assert form.save, form.errors.full_messages.to_sentence
    parts = form.entry.vest_parts.to_a

    post transactions_bulk_deletion_url, params: { bulk_delete: { entry_ids: [ *parts.map(&:id), @entry.id ] } }

    assert parts.all? { |part| Entry.exists?(part.id) }
    assert_not Entry.exists?(@entry.id)
    assert_equal I18n.t("transactions.bulk_deletions.create.vest_part", count: 2), flash[:alert]
  end
end
