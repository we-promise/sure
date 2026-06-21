require "test_helper"

class Account::ProviderImportAdapterSplitReconciliationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @adapter = Account::ProviderImportAdapter.new(@account)
  end

  # Helper: create a pending entry and split it into two children.
  def create_split_pending(amount:, external_id:, source:, date: 5.days.ago.to_date)
    entry = create_transaction(
      account: @account,
      amount: amount,
      currency: "USD",
      date: date,
      external_id: external_id,
      source: source
    )
    entry.transaction.update!(extra: { source => { "pending" => true } })

    entry.split!([
      { name: "Part A", amount: (amount * 0.6).round(2), category_id: categories(:food_and_drink).id },
      { name: "Part B", amount: (amount * 0.4).round(2), category_id: nil }
    ])

    entry.reload
  end

  # --- Exact amount, Plaid pending_transaction_id (priority 1) ---

  test "claims pending split parent via Plaid pending_transaction_id when amount matches" do
    pending_entry = create_split_pending(amount: 50.00, external_id: "plaid_pending_111", source: "plaid")
    child_ids = pending_entry.child_entries.pluck(:id)

    assert_no_difference "@account.entries.count" do
      result = @adapter.import_transaction(
        external_id: "plaid_posted_111",
        amount: 50.00,
        currency: "USD",
        date: Date.current,
        name: "STARBUCKS",
        source: "plaid",
        pending_transaction_id: "plaid_pending_111"
      )

      assert_equal pending_entry.id, result.id
      assert_equal "plaid_posted_111", result.external_id

      result.transaction.reload
      refute result.transaction.pending?, "pending flag should be cleared after claim"
      assert_includes result.transaction.extra["auto_claimed_pending_ids"], "plaid_pending_111"
    end

    # Children survive intact
    assert_equal child_ids.sort, pending_entry.child_entries.reload.pluck(:id).sort

    # Children's pending flags are also cleared so they appear in analytics
    pending_entry.child_entries.reload.each do |child|
      refute child.entryable.pending?, "split child pending flag should be cleared when parent is booked"
    end
  end

  # --- Non-terminating binary fraction: the BigDecimal-normalization regression ---

  test "claims pending split parent when Plaid float amount is a non-terminating binary fraction" do
    # 50.01 is not exactly representable in IEEE 754. Without the BigDecimal(amount.to_s)
    # normalization at import_transaction's entry point, the gate `pending_match.amount != amount`
    # compares a Float (50.01) against the exact BigDecimal in the DB and ALWAYS reports a
    # mismatch — incorrectly skipping the auto-claim and creating a duplicate posted entry.
    pending_entry = create_split_pending(amount: 50.01, external_id: "plaid_pending_5001", source: "plaid")
    child_ids = pending_entry.child_entries.pluck(:id)

    assert_no_difference "@account.entries.count", "matching float amount must auto-claim, not duplicate" do
      result = @adapter.import_transaction(
        external_id: "plaid_posted_5001",
        amount: 50.01, # Plaid delivers this as a JSON Float
        currency: "USD",
        date: Date.current,
        name: "STARBUCKS",
        source: "plaid",
        pending_transaction_id: "plaid_pending_5001"
      )

      assert_equal pending_entry.id, result.id, "split parent should be claimed despite float representation"
      assert_equal "plaid_posted_5001", result.external_id
      result.transaction.reload
      refute result.transaction.pending?, "pending flag should be cleared after claim"
    end

    # Children survive and clear their pending flags
    assert_equal child_ids.sort, pending_entry.child_entries.reload.pluck(:id).sort
    pending_entry.child_entries.reload.each do |child|
      refute child.entryable.pending?, "split child pending flag should be cleared when parent books"
    end
  end

  # --- Exact amount, SimpleFIN amount-match (priority 2) ---

  test "claims pending split parent via SimpleFIN exact amount match" do
    pending_entry = create_split_pending(amount: 80.00, external_id: "sf_pending_222", source: "simplefin")
    child_ids = pending_entry.child_entries.pluck(:id)

    assert_no_difference "@account.entries.count" do
      result = @adapter.import_transaction(
        external_id: "sf_posted_222",
        amount: 80.00,
        currency: "USD",
        date: Date.current,
        name: "WHOLE FOODS",
        source: "simplefin",
        extra: { "simplefin" => { "pending" => false } }
      )

      assert_equal pending_entry.id, result.id
      assert_equal "sf_posted_222", result.external_id

      result.transaction.reload
      refute result.transaction.pending?
      assert_includes result.transaction.extra["auto_claimed_pending_ids"], "sf_pending_222"
    end

    assert_equal child_ids.sort, pending_entry.child_entries.reload.pluck(:id).sort

    # Children's pending flags are also cleared so they appear in analytics
    pending_entry.child_entries.reload.each do |child|
      refute child.entryable.pending?, "split child pending flag should be cleared when parent is booked"
    end
  end

  # --- Amount mismatch via Plaid pending_transaction_id (tip scenario) ---

  test "does NOT auto-claim split parent when Plaid posted amount differs" do
    # Use a recent date (within the fuzzy 3-day window) and matching names so the
    # post-save fuzzy suggestion path can wire up the potential_posted_match.
    pending_entry = create_split_pending(
      amount: 45.00,
      external_id: "plaid_pending_tip",
      source: "plaid",
      date: 2.days.ago.to_date
    )
    # Override the default "Transaction" name with something the fuzzy matcher can match
    pending_entry.update!(name: "RESTAURANT")
    original_external_id = pending_entry.external_id

    # Tip raises the amount to 52.00 (15.5% diff — within 30% fuzzy tolerance)
    assert_difference "@account.entries.count", 1 do
      posted = @adapter.import_transaction(
        external_id: "plaid_posted_tip",
        amount: 52.00,
        currency: "USD",
        date: Date.current,
        name: "RESTAURANT",
        source: "plaid",
        pending_transaction_id: "plaid_pending_tip"
      )

      # The posted entry is a fresh record
      assert_not_equal pending_entry.id, posted.id
      assert_equal "plaid_posted_tip", posted.external_id
    end

    # Pending split parent is untouched
    pending_entry.reload
    assert_equal original_external_id, pending_entry.external_id
    assert pending_entry.transaction.pending?, "pending flag must remain set"
    assert pending_entry.split_parent?, "split family must remain intact"
    assert_equal 2, pending_entry.child_entries.count

    # A potential_posted_match suggestion should have been stored on the split parent
    # by the post-save fuzzy-suggestion path
    pending_entry.transaction.reload
    assert pending_entry.transaction.has_potential_duplicate?,
           "expected a potential_posted_match suggestion on the split parent"
  end

  test "stores suggestion via Plaid pending_transaction_id even when pending and posted names differ" do
    # The authoritative-link (priority 0) path: when Plaid links pending→posted by
    # pending_transaction_id but the amount differs AND the names diverge (so the fuzzy
    # name matcher would NOT match), the suggestion must still be stored using the known
    # link — otherwise the split parent is stranded pending forever and a duplicate posts.
    pending_entry = create_split_pending(
      amount: 45.00,
      external_id: "plaid_pending_namediff",
      source: "plaid",
      date: 2.days.ago.to_date
    )
    pending_entry.update!(name: "SQ *COFFEE BAR") # pending-side name
    original_external_id = pending_entry.external_id

    assert_difference "@account.entries.count", 1 do
      posted = @adapter.import_transaction(
        external_id: "plaid_posted_namediff",
        amount: 52.00, # tip
        currency: "USD",
        date: Date.current,
        name: "COFFEE BAR INC", # posted-side name diverges from pending
        source: "plaid",
        pending_transaction_id: "plaid_pending_namediff"
      )
      assert_not_equal pending_entry.id, posted.id
    end

    pending_entry.reload
    assert_equal original_external_id, pending_entry.external_id
    assert pending_entry.transaction.pending?, "pending flag must remain set"
    assert pending_entry.split_parent?, "split family must remain intact"

    pending_entry.transaction.reload
    assert pending_entry.transaction.has_potential_duplicate?,
           "authoritative-link suggestion must be stored even when names differ"
    match = pending_entry.transaction.extra["potential_posted_match"]
    assert_equal "split_parent_amount_mismatch", match["reason"]
    assert_equal "high", match["confidence"]
  end

  # --- Amount mismatch via SimpleFIN (partial post / different amount) ---

  test "does NOT auto-claim split parent when SimpleFIN posted amount differs" do
    pending_entry = create_split_pending(amount: 100.00, external_id: "sf_pending_partial", source: "simplefin")

    assert_difference "@account.entries.count", 1 do
      @adapter.import_transaction(
        external_id: "sf_posted_partial",
        amount: 95.00,
        currency: "USD",
        date: Date.current,
        name: "AMAZON",
        source: "simplefin"
      )
    end

    pending_entry.reload
    assert pending_entry.transaction.pending?, "pending flag must remain set"
    assert_equal 2, pending_entry.child_entries.count
  end

  # --- Non-split pending is still auto-claimed normally ---

  test "claims non-split pending via exact amount match as before" do
    entry = create_transaction(
      account: @account,
      amount: 60.00,
      currency: "USD",
      date: 3.days.ago.to_date,
      external_id: "sf_pending_nosplit",
      source: "simplefin"
    )
    entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    assert_no_difference "@account.entries.count" do
      result = @adapter.import_transaction(
        external_id: "sf_posted_nosplit",
        amount: 60.00,
        currency: "USD",
        date: Date.current,
        name: "UBER",
        source: "simplefin"
      )

      assert_equal entry.id, result.id
      assert_equal "sf_posted_nosplit", result.external_id
      refute result.transaction.pending?
    end
  end

  # --- Re-syncing the same pending after split triggers the protection skip ---

  test "re-syncing pending entry after split is skipped via protection flags" do
    pending_entry = create_split_pending(amount: 30.00, external_id: "sf_pending_resync", source: "simplefin")

    # split! calls mark_user_modified! on the parent; it also sets excluded: true
    assert pending_entry.user_modified?, "split! should mark parent user_modified"
    assert pending_entry.excluded?, "split! should mark parent excluded"

    # Re-importing with same external_id should skip
    assert_no_difference "@account.entries.count" do
      @adapter.import_transaction(
        external_id: "sf_pending_resync",
        amount: 30.00,
        currency: "USD",
        date: pending_entry.date,
        name: "COFFEE",
        source: "simplefin",
        extra: { "simplefin" => { "pending" => true } }
      )
    end

    # Nothing changed on the parent
    pending_entry.reload
    assert_equal 2, pending_entry.child_entries.count
    assert pending_entry.transaction.pending?
  end

  # --- Same-external-id bypass (Enable Banking / Revolut Italy path) clears children ---

  test "clears children's pending flags via same-external-id bypass when excluded split parent receives booked version" do
    pending_entry = create_split_pending(amount: 60.00, external_id: "eb_bypass_test", source: "enable_banking")
    child_ids = pending_entry.child_entries.pluck(:id)

    # split! already sets excluded: true; import with same external_id triggers the bypass path
    assert_no_difference "@account.entries.count" do
      @adapter.import_transaction(
        external_id: "eb_bypass_test",
        amount: 60.00,
        currency: "USD",
        date: Date.current,
        name: "SUPERMARKET",
        source: "enable_banking"
        # no pending extra → incoming is booked
      )
    end

    pending_entry.transaction.reload
    refute pending_entry.transaction.pending?, "parent pending flag should be cleared via same-external-id bypass"

    Entry.where(id: child_ids).each do |child|
      refute child.entryable.pending?, "split child pending flag should be cleared via same-external-id bypass"
    end
  end

  # --- The bypass must NOT clear a split parent whose booked amount differs ---

  test "same-external-id bypass leaves split family pending when booked amount differs (tip/FX/partial post)" do
    pending_entry = create_split_pending(amount: 60.00, external_id: "eb_bypass_mismatch", source: "enable_banking")
    child_ids = pending_entry.child_entries.pluck(:id)

    # Booked version arrives with a different amount (e.g. a tip was added). The bypass must
    # not silently re-enter children into analytics against stale split amounts.
    assert_no_difference "@account.entries.count" do
      @adapter.import_transaction(
        external_id: "eb_bypass_mismatch",
        amount: 72.00,
        currency: "USD",
        date: Date.current,
        name: "RESTAURANT",
        source: "enable_banking"
        # no pending extra → incoming is booked
      )
    end

    pending_entry.transaction.reload
    assert pending_entry.transaction.pending?, "split parent must stay pending when the booked amount differs"
    assert_equal 60.00.to_d, pending_entry.reload.amount, "split parent amount must be untouched on mismatch"

    Entry.where(id: child_ids).each do |child|
      assert child.entryable.pending?, "split child must stay pending when the booked amount differs"
    end
  end

  # --- The bypass must NOT touch a user-excluded standalone pending entry ---

  test "same-external-id bypass leaves a user-excluded standalone pending entry untouched" do
    entry = create_transaction(
      account: @account,
      amount: 45.00,
      currency: "USD",
      date: 3.days.ago.to_date,
      external_id: "eb_excluded_standalone",
      source: "enable_banking"
    )
    entry.transaction.update!(extra: { "enable_banking" => { "pending" => true } })
    # User manually excluded this standalone pending transaction (not a split parent).
    entry.update!(excluded: true)

    assert_no_difference "@account.entries.count" do
      @adapter.import_transaction(
        external_id: "eb_excluded_standalone",
        amount: 45.00,
        currency: "USD",
        date: Date.current,
        name: "SUPERMARKET",
        source: "enable_banking"
        # no pending extra → incoming is booked, reaches the excluded bypass branch
      )
    end

    entry.transaction.reload
    assert entry.transaction.pending?,
      "a user-excluded standalone pending entry must keep its pending flag; only split parents are cleared by the bypass"
    assert entry.reload.excluded?, "entry should remain excluded"
  end
end
