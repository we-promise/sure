require "test_helper"

class Transaction::MergeWithDuplicateTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family  = @account.family

    @category_a = categories(:food_and_drink)
    @category_b = categories(:income)

    # Pending entry — simulates a bank-synced pending transaction
    @pending_entry = create_transaction(
      account:     @account,
      name:        "Starbucks Pending",
      date:        3.days.ago.to_date,
      amount:      10,
      currency:    "USD",
      external_id: "enable_banking_PDNG123",
      source:      "enable_banking",
      category:    @category_a
    )
    @pending_entry.transaction.update!(
      extra: { "enable_banking" => { "pending" => true } }
    )

    # Posted (booked) entry — the canonical settled transaction from the bank
    @posted_entry = create_transaction(
      account:  @account,
      name:     "STARBUCKS CORP",
      date:     1.day.ago.to_date,
      amount:   10,
      currency: "USD",
      external_id: "enable_banking_BOOK456",
      source:      "enable_banking"
    )

    # Wire up the duplicate suggestion on the pending transaction
    @pending_entry.transaction.update!(
      extra: @pending_entry.transaction.extra.merge(
        "potential_posted_match" => {
          "entry_id"      => @posted_entry.id,
          "reason"        => "fuzzy_amount_match",
          "posted_amount" => "10.0",
          "confidence"    => "medium",
          "detected_at"   => Date.current.to_s,
          "dismissed"     => false
        }
      )
    )
  end

  test "destroys the pending entry on successful merge" do
    pending_id = @pending_entry.id
    assert_difference "Entry.count", -1 do
      @pending_entry.transaction.merge_with_duplicate!
    end
    assert_nil Entry.find_by(id: pending_id)
  end

  test "records merged_from_external_id on the surviving posted transaction" do
    @pending_entry.transaction.merge_with_duplicate!

    posted_tx = @posted_entry.transaction.reload
    assert_equal "enable_banking_PDNG123", posted_tx.extra.dig("manual_merge", 0, "merged_from_external_id")
  end

  test "records merged_from_entry_id and source in manual_merge metadata" do
    pending_id = @pending_entry.id
    @pending_entry.transaction.merge_with_duplicate!

    merge_meta = @posted_entry.transaction.reload.extra["manual_merge"].first
    assert_equal pending_id, merge_meta["merged_from_entry_id"]
    assert_equal "enable_banking", merge_meta["source"]
    assert merge_meta["merged_at"].present?
  end

  test "appends to existing manual_merge array preserving prior merged IDs" do
    # Seed a prior merge record directly so the posted entry already has one ID
    prior_ext_id = "enable_banking_PDNG_PRIOR"
    @posted_entry.transaction.update!(
      extra: {
        "manual_merge" => [
          { "merged_from_external_id" => prior_ext_id, "merged_at" => 1.day.ago.iso8601, "source" => "enable_banking" }
        ]
      }
    )

    @pending_entry.transaction.merge_with_duplicate!

    records = @posted_entry.transaction.reload.extra["manual_merge"]
    assert_equal 2, records.size
    assert_includes records.map { |r| r["merged_from_external_id"] }, prior_ext_id
    assert_includes records.map { |r| r["merged_from_external_id"] }, "enable_banking_PDNG123"
  end

  test "migrates legacy single-object manual_merge to array on second merge" do
    # Simulate an existing record written in the old single-Hash format
    @posted_entry.transaction.update!(
      extra: {
        "manual_merge" => {
          "merged_from_external_id" => "enable_banking_LEGACY",
          "merged_at"               => 1.day.ago.iso8601,
          "source"                  => "enable_banking"
        }
      }
    )

    @pending_entry.transaction.merge_with_duplicate!

    records = @posted_entry.transaction.reload.extra["manual_merge"]
    assert_kind_of Array, records
    assert_equal 2, records.size
    assert_includes records.map { |r| r["merged_from_external_id"] }, "enable_banking_LEGACY"
    assert_includes records.map { |r| r["merged_from_external_id"] }, "enable_banking_PDNG123"
  end

  test "inherits date from pending entry onto posted entry" do
    original_posted_date = @posted_entry.date
    pending_date = @pending_entry.date
    refute_equal original_posted_date, pending_date

    @pending_entry.transaction.merge_with_duplicate!

    assert_equal pending_date, @posted_entry.reload.date
  end

  test "inherits category from pending entry onto posted entry" do
    assert_nil @posted_entry.transaction.category_id

    @pending_entry.transaction.merge_with_duplicate!

    assert_equal @category_a.id, @posted_entry.transaction.reload.category_id
  end

  test "overwrites existing category on posted entry with pending category" do
    @posted_entry.transaction.update!(category: @category_b)

    @pending_entry.transaction.merge_with_duplicate!

    assert_equal @category_a.id, @posted_entry.transaction.reload.category_id
  end

  test "does not inherit name from pending — booked name is canonical" do
    @pending_entry.transaction.merge_with_duplicate!

    assert_equal "STARBUCKS CORP", @posted_entry.reload.name
  end

  test "marks the posted entry as user_modified to prevent future sync overwrites" do
    refute @posted_entry.user_modified?

    @pending_entry.transaction.merge_with_duplicate!

    assert @posted_entry.reload.user_modified?
  end

  test "returns true on success" do
    result = @pending_entry.transaction.merge_with_duplicate!
    assert_equal true, result
  end

  test "returns false when no potential duplicate is set" do
    @pending_entry.transaction.update!(extra: {})
    result = @pending_entry.transaction.merge_with_duplicate!
    assert_equal false, result
  end

  test "returns false when the suggested posted entry no longer exists" do
    @posted_entry.destroy!
    result = @pending_entry.transaction.merge_with_duplicate!
    assert_equal false, result
  end

  test "returns false and does not destroy pending entry when posted entry is on a different account" do
    other_account = accounts(:credit_card)
    @posted_entry.update!(account: other_account)

    result = nil
    assert_no_difference "Entry.count" do
      result = @pending_entry.transaction.merge_with_duplicate!
    end
    assert_equal false, result
  end

  test "does not update date or category when posted entry is already user_modified" do
    # Give posted entry a category so we can assert it was preserved (avoids nil==nil comparison)
    @posted_entry.transaction.update!(category: @category_b)
    original_date     = @posted_entry.reload.date
    original_category = @posted_entry.transaction.reload.category_id
    @posted_entry.mark_user_modified!

    @pending_entry.transaction.merge_with_duplicate!

    assert_equal original_date,     @posted_entry.reload.date
    assert_equal original_category, @posted_entry.transaction.reload.category_id
  end

  test "still records merge metadata even when posted entry is already user_modified" do
    @posted_entry.mark_user_modified!

    @pending_entry.transaction.merge_with_duplicate!

    assert_equal "enable_banking_PDNG123",
                 @posted_entry.transaction.reload.extra.dig("manual_merge", 0, "merged_from_external_id")
  end

  test "is idempotent when pending entry is already destroyed (concurrent merge)" do
    @pending_entry.destroy!

    result = nil
    assert_no_difference "Entry.count" do
      result = @pending_entry.transaction.merge_with_duplicate!
    end
    assert_equal true, result
  end

  test "skips storing merge metadata when pending entry has no external_id" do
    @pending_entry.update!(external_id: nil)

    @pending_entry.transaction.merge_with_duplicate!

    merge_meta = @posted_entry.transaction.reload.extra&.dig("manual_merge")
    assert_nil merge_meta
  end

  # --- C-1: concurrent deletion of posted entry ---

  test "returns false when posted entry is deleted between check and lock" do
    # Simulate the race: posted_entry exists at find_by time but is gone at lock! time.
    # Use a stub rather than dup so id and account_id are real values — dup gives id: nil.
    ghost = stub(account_id: @posted_entry.account_id, id: @posted_entry.id)
    ghost.stubs(:lock!).raises(ActiveRecord::RecordNotFound)
    @pending_entry.transaction.stubs(:potential_duplicate_entry).returns(ghost)

    result = nil
    assert_no_difference "Entry.count" do
      result = @pending_entry.transaction.merge_with_duplicate!
    end
    assert_equal false, result
  end

  # --- cascade: delegated_type dependent: :destroy removes the Transaction too ---

  test "destroys the pending Transaction record on successful merge" do
    assert_difference "Transaction.count", -1 do
      @pending_entry.transaction.merge_with_duplicate!
    end
  end

  # --- dismiss_duplicate_suggestion! ---

  test "dismiss_duplicate_suggestion! sets dismissed flag on the match" do
    @pending_entry.transaction.dismiss_duplicate_suggestion!
    assert_equal true, @pending_entry.transaction.reload.extra.dig("potential_posted_match", "dismissed")
  end

  test "dismiss_duplicate_suggestion! makes has_potential_duplicate? return false" do
    @pending_entry.transaction.dismiss_duplicate_suggestion!
    assert_not @pending_entry.transaction.reload.has_potential_duplicate?
  end

  test "dismiss_duplicate_suggestion! returns false when no suggestion is present" do
    @pending_entry.transaction.update!(extra: {})
    assert_equal false, @pending_entry.transaction.dismiss_duplicate_suggestion!
  end

  test "merge_with_duplicate! returns false when suggestion has been dismissed" do
    @pending_entry.transaction.dismiss_duplicate_suggestion!
    assert_equal false, @pending_entry.transaction.reload.merge_with_duplicate!
  end

  # --- clear_duplicate_suggestion! ---

  test "clear_duplicate_suggestion! removes potential_posted_match key entirely" do
    @pending_entry.transaction.clear_duplicate_suggestion!
    assert_nil @pending_entry.transaction.reload.extra["potential_posted_match"]
  end

  test "clear_duplicate_suggestion! returns false when no suggestion is present" do
    @pending_entry.transaction.update!(extra: {})
    assert_equal false, @pending_entry.transaction.clear_duplicate_suggestion!
  end

  # --- pending_duplicate_candidates ---

  test "pending_duplicate_candidates returns posted transactions from the same account" do
    candidates = @pending_entry.transaction.pending_duplicate_candidates
    assert_includes candidates, @posted_entry
  end

  test "pending_duplicate_candidates excludes the pending entry itself" do
    candidates = @pending_entry.transaction.pending_duplicate_candidates
    assert_not_includes candidates, @pending_entry
  end

  test "pending_duplicate_candidates excludes transactions from other accounts" do
    other_entry = create_transaction(account: accounts(:credit_card), amount: 10, currency: "USD")
    candidates = @pending_entry.transaction.pending_duplicate_candidates
    assert_not_includes candidates, other_entry
  end

  test "pending_duplicate_candidates returns Entry.none when transaction is not pending" do
    @pending_entry.transaction.update!(extra: {})
    assert_equal [], @pending_entry.transaction.pending_duplicate_candidates.to_a
  end
end
