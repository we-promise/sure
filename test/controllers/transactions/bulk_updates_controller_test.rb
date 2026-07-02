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

  test "bulk update clears tags when tag_ids is blank string array (web multi-select None)" do
    transaction_entry = @user.family.entries.transactions.first
    original_tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.tags = original_tags
    transaction_entry.transaction.save!

    # For a multiple select, choosing the blank ("None") option submits a blank value.
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: Category.second.id,
        tag_ids: [ "" ]
      }
    }

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    assert_empty transaction_entry.transaction.tags
  end

  test "bulk update clears tags when empty tag_ids explicitly provided (JSON)" do
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ Tag.first, Tag.second ]
    transaction_entry.transaction.save!

    post transactions_bulk_update_url,
         params: {
           bulk_update: {
             entry_ids: [ transaction_entry.id ],
             category_id: Category.second.id,
             tag_ids: []
           }
         },
         as: :json

    assert_redirected_to transactions_url

    transaction_entry.reload
    assert_equal Category.second, transaction_entry.transaction.category
    assert_empty transaction_entry.transaction.tags
  end

  test "bulk update rejects private account entries for members without access" do
    member = users(:family_member)
    private_account = accounts(:investment)
    category = Category.second

    entry = private_account.entries.create!(
      name: "Private bulk target",
      date: Date.current,
      amount: -20,
      currency: "USD",
      entryable: Transaction.new(category: category, kind: "standard")
    )

    sign_in member

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        category_id: category.id,
        notes: "Should not apply"
      }
    }

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.bulk_updates.permission_error"), flash[:alert]
    assert_not_equal "Should not apply", entry.reload.notes
  end

  test "read_write member can bulk annotate but not change structural fields" do
    member = users(:family_member)
    account = accounts(:investment)
    account.share_with!(member, permission: "read_write")

    category = Category.second
    entry = account.entries.create!(
      name: "Annotatable bulk target",
      date: Date.current,
      amount: -30,
      currency: "USD",
      entryable: Transaction.new(category: category, kind: "standard")
    )

    sign_in member

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        notes: "Annotated in bulk"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "1 transactions updated", flash[:notice]
    assert_equal "Annotated in bulk", entry.reload.notes

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        date: 2.days.ago.to_date
      }
    }

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.bulk_updates.permission_error"), flash[:alert]
    assert_equal Date.current, entry.reload.date
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
