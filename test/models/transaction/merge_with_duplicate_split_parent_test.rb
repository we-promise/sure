require "test_helper"

class Transaction::MergeWithDuplicateSplitParentTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)

    @pending_entry = create_transaction(
      account: @account,
      name: "Grocery Store Pending",
      date: 3.days.ago.to_date,
      amount: 100,
      currency: "USD",
      external_id: "sf_pending_split_merge_test",
      source: "simplefin"
    )
    @pending_entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    @posted_entry = create_transaction(
      account: @account,
      name: "GROCERY STORE",
      date: 1.day.ago.to_date,
      amount: 115,
      currency: "USD",
      external_id: "sf_posted_split_merge_test",
      source: "simplefin"
    )

    @pending_entry.transaction.update!(
      extra: @pending_entry.transaction.extra.merge(
        "potential_posted_match" => {
          "entry_id"      => @posted_entry.id,
          "reason"        => "fuzzy_amount_match",
          "posted_amount" => "115.0",
          "confidence"    => "medium",
          "detected_at"   => Date.current.to_s,
          "dismissed"     => false
        }
      )
    )

    # Split the pending entry into two parts
    @pending_entry.split!([
      { name: "Groceries", amount: 70, category_id: categories(:food_and_drink).id },
      { name: "Household", amount: 30, category_id: nil }
    ])
    @pending_entry.reload
  end

  test "merge_with_duplicate! returns false when pending entry is a split parent" do
    pending_transaction = @pending_entry.transaction

    result = pending_transaction.merge_with_duplicate!

    refute result, "merge should be blocked for split parents"
  end

  test "children survive when merge is blocked for split parent" do
    child_ids = @pending_entry.child_entries.pluck(:id)

    @pending_entry.transaction.merge_with_duplicate!

    assert_equal 2, @pending_entry.child_entries.reload.count
    assert_equal child_ids.sort, Entry.where(id: child_ids).pluck(:id).sort
  end

  test "pending entry itself survives when merge is blocked" do
    pending_id = @pending_entry.id

    @pending_entry.transaction.merge_with_duplicate!

    assert Entry.exists?(pending_id), "pending split parent entry must not be destroyed"
  end

  test "posted entry survives when merge is blocked" do
    posted_id = @posted_entry.id

    @pending_entry.transaction.merge_with_duplicate!

    assert Entry.exists?(posted_id)
  end
end
