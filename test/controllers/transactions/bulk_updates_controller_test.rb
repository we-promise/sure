require "test_helper"

class Transactions::BulkUpdatesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

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

  test "bulk update preloads transaction records" do
    transaction_ids = @user.family.entries.transactions.limit(4).pluck(:id)

    queries = capture_sql_queries do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: transaction_ids,
          notes: "Updated in bulk"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_empty queries.grep(
      /SELECT "transactions"\.\* FROM "transactions" WHERE "transactions"\."id" =/
    )
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

  test "bulk update sets reconciled_status on manual accounts" do
    manual_entry = create_transaction(account: accounts(:depository))
    assert accounts(:depository).manual?

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ manual_entry.id ],
        reconciled_status: "reconciled"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "reconciled", manual_entry.reload.reconciled_status
  end

  test "bulk update ignores reconciled_status on synced accounts" do
    synced_entry = create_transaction(account: accounts(:connected))
    assert_not accounts(:connected).manual?

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ synced_entry.id ],
        reconciled_status: "reconciled"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "unreconciled", synced_entry.reload.reconciled_status
  end

  test "bulk update does not modify entries on accounts the user only has read-only access to" do
    read_only_user = users(:family_member)
    sign_in read_only_user

    # family_member has read_only access to credit_card (see account_shares fixture)
    read_only_account = accounts(:credit_card)
    assert_not Account.writable_by(read_only_user).exists?(id: read_only_account.id)

    read_only_entry = create_transaction(account: read_only_account, name: "Not mine to edit")

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ read_only_entry.id ],
        reconciled_status: "reconciled",
        notes: "Should not be applied"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "0 transactions updated", flash[:notice]

    read_only_entry.reload
    assert_equal "unreconciled", read_only_entry.reconciled_status
    assert_nil read_only_entry.notes
  end

  test "bulk update rejects an invalid reconciled_status value without raising" do
    manual_entry = create_transaction(account: accounts(:depository))

    assert_no_changes -> { manual_entry.reload.reconciled_status } do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: [ manual_entry.id ],
          reconciled_status: "not_a_real_status"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.reconcile.failure"), flash[:alert]
  end
end
