require "test_helper"

class Transactions::BulkUpdatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "bulk update" do
    transactions = @user.family.entries.transactions

    assert_difference [ "Entry.count", "Transaction.count" ], 0 do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: transactions.map(&:id),
          date: 1.day.ago.to_date,
          category_id: Category.second.id,
          merchant_id: Merchant.second.id,
          tag_ids: [ Tag.first.id, Tag.second.id ],
          notes: "Updated note"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "#{transactions.count} transactions updated", flash[:notice]

    transactions.reload.each do |transaction|
      assert_equal 1.day.ago.to_date, transaction.date
      assert_equal Category.second, transaction.transaction.category
      assert_equal Merchant.second, transaction.transaction.merchant
      assert_equal "Updated note", transaction.notes
      assert_equal [ Tag.first.id, Tag.second.id ], transaction.entryable.tag_ids.sort
    end
  end

  test "bulk update preserves tags when tag_ids not provided" do
    transaction_entry = @user.family.entries.transactions.first
    original_tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.tags = original_tags
    transaction_entry.transaction.save!

    # Update only the category, without providing tag_ids
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: Category.second.id
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    # Tags should be preserved since tag_ids was not in the request
    assert_equal original_tags.map(&:id).sort, transaction_entry.transaction.tag_ids.sort
  end

  test "bulk update clears tags when empty tag_ids explicitly provided" do
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.save!

    # Explicitly provide empty tag_ids to clear tags
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: Category.second.id,
        tag_ids: []
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    # Tags should be cleared since tag_ids was explicitly provided as empty
    assert_empty transaction_entry.transaction.tags
  end

  test "bulk update replaces tags when tag_ids explicitly provided" do
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ Tag.first ]
    transaction_entry.transaction.save!

    new_tag = Tag.second

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        tag_ids: [ new_tag.id ]
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal [ new_tag.id ], transaction_entry.transaction.tag_ids
  end
end
