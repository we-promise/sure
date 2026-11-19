require "test_helper"

class Transactions::BulkUpdatesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "bulk update" do
    transfer_entry_ids = [ entries(:transfer_out).id, entries(:transfer_in).id ]
    transactions = @user.family.entries.transactions.where.not(id: transfer_entry_ids)

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

  test "bulk update keeps transfer date, category and merchant" do
    @user.family.update!(manual_reconciliation: true)
    transfer = create_transfer(
      from_account: accounts(:depository),
      to_account: accounts(:credit_card),
      amount: 100,
      date: Date.current
    )
    outflow_entry = transfer.outflow_transaction.entry
    inflow_entry = transfer.inflow_transaction.entry
    original_date = outflow_entry.date

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ outflow_entry.id ],
        date: 1.day.ago.to_date,
        category_id: Category.second.id,
        merchant_id: Merchant.second.id,
        tag_ids: [ Tag.first.id ],
        notes: "Transfer note",
        reconciled_status: "reconciled"
      }
    }

    assert_redirected_to transactions_url
    outflow_entry.reload
    assert_equal original_date, outflow_entry.date
    assert_nil outflow_entry.transaction.category_id
    assert_nil outflow_entry.transaction.merchant_id
    assert_equal "Transfer note", outflow_entry.notes
    assert_equal [ Tag.first.id ], outflow_entry.transaction.tag_ids
    assert_equal "reconciled", outflow_entry.reconciled_status

    inflow_entry.reload
    assert_equal original_date, inflow_entry.date
    assert_nil inflow_entry.transaction.category_id
    assert_equal "unreconciled", inflow_entry.reconciled_status
  end

  test "bulk update applies a category to a categorizable transfer outflow" do
    transfer = create_transfer(
      from_account: accounts(:depository),
      to_account: accounts(:investment),
      amount: 100
    )
    outflow_entry = transfer.outflow_transaction.entry

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ outflow_entry.id ],
        category_id: Category.second.id
      }
    }

    assert_redirected_to transactions_url
    assert_equal Category.second.id, outflow_entry.reload.transaction.category_id
  end

  test "bulk update keeps an unmatched transfer-kind transaction editable" do
    entry = create_transaction(
      account: accounts(:depository),
      kind: "funds_movement",
      name: "Unmatched transfer"
    )
    original_date = entry.date

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        date: 1.day.ago.to_date,
        category_id: Category.second.id,
        merchant_id: Merchant.second.id,
        tag_ids: [ Tag.first.id ],
        notes: "Edited unmatched transfer"
      }
    }

    assert_redirected_to transactions_url
    entry.reload
    assert_not_equal original_date, entry.date
    assert_equal 1.day.ago.to_date, entry.date
    assert_equal Category.second, entry.transaction.category
    assert_equal Merchant.second, entry.transaction.merchant
    assert_equal "Edited unmatched transfer", entry.notes
    assert_equal [ Tag.first.id ], entry.transaction.tag_ids
  end

  test "bulk update keeps transfer fee transactions editable" do
    transfer = create_transfer(
      from_account: accounts(:depository),
      to_account: accounts(:credit_card),
      amount: 100
    )
    fee_entry = accounts(:depository).entries.create!(
      name: "Transfer fee",
      date: Date.current,
      amount: 10,
      currency: "USD",
      entryable: Transaction.new(kind: "standard", transfer: transfer)
    )

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ fee_entry.id ],
        date: 1.day.ago.to_date,
        category_id: Category.second.id,
        merchant_id: Merchant.second.id,
        tag_ids: [ Tag.first.id ],
        notes: "Edited fee"
      }
    }

    assert_redirected_to transactions_url
    fee_entry.reload
    assert_equal 1.day.ago.to_date, fee_entry.date
    assert_equal Category.second, fee_entry.transaction.category
    assert_equal Merchant.second, fee_entry.transaction.merchant
    assert_equal "Edited fee", fee_entry.notes
    assert_equal [ Tag.first.id ], fee_entry.transaction.tag_ids
  end

  test "bulk update applies safe fields to both selected transfer legs" do
    @user.family.update!(manual_reconciliation: true)
    transfer = create_transfer(
      from_account: accounts(:depository),
      to_account: accounts(:credit_card),
      amount: 100
    )
    outflow_entry = transfer.outflow_transaction.entry
    inflow_entry = transfer.inflow_transaction.entry
    original_date = outflow_entry.date

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ outflow_entry.id, inflow_entry.id ],
        date: 1.day.ago.to_date,
        category_id: Category.second.id,
        merchant_id: Merchant.second.id,
        tag_ids: [ Tag.first.id ],
        notes: "Both legs",
        reconciled_status: "reconciled"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "2 transactions updated", flash[:notice]

    [ outflow_entry, inflow_entry ].each do |entry|
      entry.reload
      assert_equal original_date, entry.date
      assert_nil entry.transaction.category_id
      assert_nil entry.transaction.merchant_id
      assert_equal "Both legs", entry.notes
      assert_equal [ Tag.first.id ], entry.transaction.tag_ids
      assert_equal "reconciled", entry.reconciled_status
    end
  end

  test "bulk update applies normal fields to normal entries and safe fields to a transfer" do
    @user.family.update!(manual_reconciliation: true)
    normal_entry = create_transaction(account: accounts(:depository), name: "Normal entry")
    transfer = create_transfer(
      from_account: accounts(:depository),
      to_account: accounts(:credit_card),
      amount: 100
    )
    outflow_entry = transfer.outflow_transaction.entry
    transfer_date = outflow_entry.date

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ normal_entry.id, outflow_entry.id ],
        date: 1.day.ago.to_date,
        category_id: Category.second.id,
        merchant_id: Merchant.second.id,
        tag_ids: [ Tag.first.id ],
        notes: "Mixed update",
        reconciled_status: "reconciled"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "2 transactions updated", flash[:notice]

    normal_entry.reload
    assert_equal 1.day.ago.to_date, normal_entry.date
    assert_equal Category.second, normal_entry.transaction.category
    assert_equal Merchant.second, normal_entry.transaction.merchant
    assert_equal "Mixed update", normal_entry.notes
    assert_equal [ Tag.first.id ], normal_entry.transaction.tag_ids
    assert_equal "reconciled", normal_entry.reconciled_status

    outflow_entry.reload
    assert_equal transfer_date, outflow_entry.date
    assert_nil outflow_entry.transaction.category_id
    assert_nil outflow_entry.transaction.merchant_id
    assert_equal "Mixed update", outflow_entry.notes
    assert_equal [ Tag.first.id ], outflow_entry.transaction.tag_ids
    assert_equal "reconciled", outflow_entry.reconciled_status
  end

  test "bulk update ignores entries from inaccessible accounts" do
    entry = create_transaction(account: accounts(:investment), name: "Private entry")
    entry.update!(notes: "Original note")

    sign_in users(:family_member)

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ entry.id ],
        notes: "Should not apply"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "0 transactions updated", flash[:notice]
    assert_equal "Original note", entry.reload.notes
  end

  test "bulk update does not look up transfers per normal entry" do
    transfer_entry_ids = [ entries(:transfer_out).id, entries(:transfer_in).id ]
    transaction_ids = @user.family.entries.transactions
      .where.not(id: transfer_entry_ids)
      .limit(5)
      .pluck(:id)

    queries = capture_sql_queries do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: transaction_ids,
          date: 1.day.ago.to_date,
          category_id: Category.second.id
        }
      }
    end

    transfer_queries = queries.grep(/FROM "?transfers"?/)
    assert_equal 1, transfer_queries.size,
      "expected one transfer-leg lookup, got: #{transfer_queries.inspect}"
  end

  test "new hides the reconciliation field when the selection has no transaction" do
    @user.family.update!(manual_reconciliation: true)

    get new_transactions_bulk_update_url, params: {
      has_transaction_entry: "false",
      has_transfer_entry: "false",
      has_category_editable_entry: "false",
      has_normal_transaction_entry: "false"
    }

    assert_response :success
    assert_select "select[name='bulk_update[reconciled_status]']", count: 0
    assert_select "input[name='bulk_update[date]']"
    assert_select "input[name='bulk_update[category_id]']", count: 0
    assert_select "input[name='bulk_update[merchant_id]']", count: 0
  end

  test "new hides transfer-unsafe fields for a non-categorizable transfer" do
    @user.family.update!(manual_reconciliation: true)

    get new_transactions_bulk_update_url, params: {
      has_transaction_entry: "true",
      has_transfer_entry: "true",
      has_category_editable_entry: "false",
      has_normal_transaction_entry: "false"
    }

    assert_response :success
    assert_select "select[name='bulk_update[reconciled_status]']"
    assert_select "input[name='bulk_update[date]']", count: 0
    assert_select "input[name='bulk_update[category_id]']", count: 0
    assert_select "input[name='bulk_update[merchant_id]']", count: 0
    assert_select "input[name='bulk_update[name]']"
    assert_select "textarea[name='bulk_update[notes]']"
  end

  test "new keeps category for a categorizable transfer outflow" do
    @user.family.update!(manual_reconciliation: true)

    get new_transactions_bulk_update_url, params: {
      has_transaction_entry: "true",
      has_transfer_entry: "true",
      has_category_editable_entry: "true",
      has_normal_transaction_entry: "false"
    }

    assert_response :success
    assert_select "select[name='bulk_update[reconciled_status]']"
    assert_select "input[name='bulk_update[date]']", count: 0
    assert_select "input[name='bulk_update[category_id]']"
    assert_select "input[name='bulk_update[merchant_id]']", count: 0
  end

  test "new keeps category and merchant for a mixed selection" do
    @user.family.update!(manual_reconciliation: true)

    get new_transactions_bulk_update_url, params: {
      has_transaction_entry: "true",
      has_transfer_entry: "true",
      has_category_editable_entry: "true",
      has_normal_transaction_entry: "true"
    }

    assert_response :success
    assert_select "select[name='bulk_update[reconciled_status]']"
    assert_select "input[name='bulk_update[date]']", count: 0
    assert_select "input[name='bulk_update[category_id]']"
    assert_select "input[name='bulk_update[merchant_id]']"
  end

  test "new shows all fields by default" do
    @user.family.update!(manual_reconciliation: true)

    get new_transactions_bulk_update_url

    assert_response :success
    assert_select "select[name='bulk_update[reconciled_status]']"
    assert_select "input[name='bulk_update[date]']"
    assert_select "input[name='bulk_update[category_id]']"
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

    sign_in users(:family_member)

    assert_no_changes -> { entry.reload.transaction.category } do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: [ entry.id ],
          category_id: categories(:food_and_drink).id,
          notes: "Changed by a read-only member"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "0 transactions updated", flash[:notice]
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

  test "bulk update locks the whole mixed selection before it writes" do
    accounts(:credit_card).account_shares.find_by!(user: users(:family_member)).update!(permission: "read_write")
    full_entry = create_transaction(account: accounts(:depository), name: "Full")
    annotate_entry = create_transaction(account: accounts(:credit_card), name: "Annotate")

    payloads = []
    callback = ->(_name, _started, _finished, _unique_id, payload) { payloads << payload }

    sign_in users(:family_member)
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      post transactions_bulk_update_url, params: {
        bulk_update: { entry_ids: [ full_entry.id, annotate_entry.id ], notes: "bulk note" }
      }
    end

    assert_equal "2 transactions updated", flash[:notice]

    transaction_lock_index = payloads.index do |payload|
      payload[:sql].include?("FOR UPDATE") && payload[:sql].include?('"transactions"')
    end
    entry_lock_indexes = payloads.each_index.select do |index|
      payloads[index][:sql].include?("FOR UPDATE") && payloads[index][:sql].include?('"entries"')
    end
    first_update_index = payloads.index { |payload| payload[:sql].start_with?('UPDATE "entries"') }

    assert transaction_lock_index, "expected a lock on the transactions"
    assert entry_lock_indexes.any?, "expected a lock on the entries"
    assert first_update_index, "expected an entry update"

    first_entry_lock = payloads[entry_lock_indexes.first]
    locked_ids = first_entry_lock[:binds].flat_map { |bind| Array(bind.value) }
    assert_includes locked_ids, full_entry.id,
      "the first entry lock must cover the full-control entry"
    assert_includes locked_ids, annotate_entry.id,
      "the first entry lock must cover the annotate-only entry"

    assert_operator transaction_lock_index, :<, entry_lock_indexes.first,
      "the transactions must be locked before the entries"
    assert_operator entry_lock_indexes.first, :<, first_update_index,
      "the whole selection must be locked before the first write"
  end

  test "bulk update sets reconciled_status on manual accounts" do
    @user.family.update!(manual_reconciliation: true)
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

  test "bulk update ignores reconciled_status on a valuation" do
    @user.family.update!(manual_reconciliation: true)
    valuation = create_valuation(account: accounts(:depository))

    post transactions_bulk_update_url, params: {
      bulk_update: {
        entry_ids: [ valuation.id ],
        reconciled_status: "reconciled"
      }
    }

    assert_redirected_to transactions_url
    assert_equal "unreconciled", valuation.reload.reconciled_status
  end

  test "bulk update ignores reconciled_status on synced accounts" do
    @user.family.update!(manual_reconciliation: true)
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

  test "bulk update rejects an invalid reconciled_status value without raising" do
    @user.family.update!(manual_reconciliation: true)
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

  test "bulk update records a debug log entry when the update fails" do
    manual_entry = create_transaction(account: accounts(:depository))
    Entry.stubs(:bulk_update!).raises(ActiveRecord::RecordInvalid.new(manual_entry))

    assert_difference -> { DebugLogEntry.where(category: "reconciliation", level: "error").count }, 1 do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: [ manual_entry.id ],
          notes: "Updated note"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.reconcile.failure"), flash[:alert]

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "Transactions::BulkUpdatesController#create", log_entry.source
    assert_equal @user.family, log_entry.family
    assert_equal @user, log_entry.user
    assert_equal [ manual_entry.id ], log_entry.metadata["entry_ids"]
  end

  test "bulk update rejects reconciled_status when manual reconciliation is disabled" do
    manual_entry = create_transaction(account: accounts(:depository))

    assert_no_changes -> { manual_entry.reload.reconciled_status } do
      post transactions_bulk_update_url, params: {
        bulk_update: {
          entry_ids: [ manual_entry.id ],
          reconciled_status: "cleared"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("transactions.reconcile.unavailable"), flash[:alert]
  end
end
