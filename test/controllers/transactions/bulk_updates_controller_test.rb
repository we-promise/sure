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

  test "bulk update ignores category, merchant and tag ids from another family" do
    other_family = families(:empty)
    foreign_category = other_family.categories.create!(name: "Foreign category")
    foreign_merchant = FamilyMerchant.create!(family: other_family, name: "Foreign merchant")
    foreign_tag = other_family.tags.create!(name: "Foreign tag")

    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.update!(category: categories(:food_and_drink), merchant: merchants(:netflix))
    transaction_entry.transaction.tags = [ tags(:one) ]
    transaction_entry.transaction.save!

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ transaction_entry.id ],
        category_id: foreign_category.id,
        merchant_id: foreign_merchant.id,
        tag_ids: [ foreign_tag.id, tags(:two).id ]
      }
    }

    assert_redirected_to transactions_url

    transaction = transaction_entry.reload.transaction
    assert_equal categories(:food_and_drink), transaction.category
    assert_equal merchants(:netflix), transaction.merchant
    assert_equal [ tags(:two).id ], transaction.tag_ids
    assert_empty foreign_tag.taggings
  end

  test "bulk update keeps existing tags when every requested tag belongs to another family" do
    foreign_tag = families(:empty).tags.create!(name: "Foreign tag")
    transaction_entry = @user.family.entries.transactions.first
    transaction_entry.transaction.tags = [ tags(:one) ]
    transaction_entry.transaction.save!

    post transactions_bulk_update_url, params: {
      bulk_update: { entry_ids: [ transaction_entry.id ], tag_ids: [ foreign_tag.id ] }
    }

    assert_equal [ tags(:one).id ], transaction_entry.reload.transaction.tag_ids
  end

  test "bulk update lets a read_write share annotate but not change date or name" do
    account = accounts(:credit_card)
    account.account_shares.find_by!(user: users(:family_member)).update!(permission: "read_write")
    entry = create_transaction(account: account, name: "Original name", date: Date.new(2026, 1, 5))

    sign_in users(:family_member)
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        name: "Renamed", date: "2026-02-10", notes: "annotated", category_id: categories(:food_and_drink).id
      }
    }

    entry.reload
    assert_equal "Original name", entry.name
    assert_equal Date.new(2026, 1, 5), entry.date
    assert_equal "annotated", entry.notes
    assert_equal categories(:food_and_drink), entry.transaction.category
  end

  test "bulk update skips entries from accounts the user can only read" do
    read_only_account = accounts(:credit_card) # shared read_only with family_member
    entry = create_transaction(account: read_only_account, name: "Starbucks")
    original_category = entry.transaction.category

    sign_in users(:family_member)

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        category_id: categories(:food_and_drink).id,
        notes: "Changed by a read-only member"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "0 transactions updated", flash[:notice]
    assert_equal original_category, entry.reload.transaction.category
    assert_nil entry.notes
  end

  test "bulk update skips entries from accounts not shared with the user" do
    entry = create_transaction(account: accounts(:other_asset), name: "Private entry")

    sign_in users(:family_member)
    post transactions_bulk_update_url, params: {
      bulk_update: { entry_ids: [ entry.id ], name: "Renamed", notes: "Changed by another member" }
    }

    assert_equal "0 transactions updated", flash[:notice]
    entry.reload
    assert_equal "Private entry", entry.name
    assert_nil entry.notes
  end

  test "bulk update lets a full_control share change date and name" do
    entry = create_transaction(account: accounts(:depository), name: "Original name", date: Date.new(2026, 1, 5))

    sign_in users(:family_member)
    post transactions_bulk_update_url, params: {
      bulk_update: { entry_ids: [ entry.id ], name: "Renamed", date: "2026-02-10" }
    }

    assert_equal "1 transactions updated", flash[:notice]
    entry.reload
    assert_equal "Renamed", entry.name
    assert_equal Date.new(2026, 2, 10), entry.date
  end

  test "bulk update applies each share's rights within one mixed selection" do
    accounts(:credit_card).account_shares.find_by!(user: users(:family_member)).update!(permission: "read_write")
    full_entry = create_transaction(account: accounts(:depository), name: "Full", date: Date.new(2026, 1, 5))
    annotate_entry = create_transaction(account: accounts(:credit_card), name: "Annotate", date: Date.new(2026, 1, 5))
    private_entry = create_transaction(account: accounts(:other_asset), name: "Private", date: Date.new(2026, 1, 5))

    sign_in users(:family_member)
    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ full_entry.id, annotate_entry.id, private_entry.id ],
        name: "Renamed", notes: "bulk note"
      }
    }

    assert_equal "2 transactions updated", flash[:notice]
    assert_equal [ "Renamed", "bulk note" ], [ full_entry.reload.name, full_entry.notes ]
    assert_equal [ "Annotate", "bulk note" ], [ annotate_entry.reload.name, annotate_entry.notes ]
    assert_equal [ "Private", nil ], [ private_entry.reload.name, private_entry.notes ]
  end
end
