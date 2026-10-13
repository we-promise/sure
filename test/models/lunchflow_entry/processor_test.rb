require "test_helper"

class LunchflowEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @lunchflow_item = LunchflowItem.create!(
      name: "Test Lunchflow Connection",
      api_key: "test_key",
      family: @family
    )
    @lunchflow_account = LunchflowAccount.create!(
      lunchflow_item: @lunchflow_item,
      name: "Test Account",
      currency: "USD",
      account_id: "lf_acc_123"
    )

    # Create a real account and link it
    @account = Account.create!(
      family: @family,
      name: "Test Checking",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "USD"
    )

    AccountProvider.create!(
      account: @account,
      provider: @lunchflow_account
    )

    @lunchflow_account.reload
  end

  test "stores pending metadata when isPending is true" do
    transaction_data = {
      id: "lf_txn_123",
      accountId: 456,
      amount: -50.00,
      currency: "USD",
      date: "2025-01-15",
      merchant: "Test Merchant",
      description: "Test transaction",
      isPending: true
    }

    result = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    transaction = result.entryable
    assert_kind_of Transaction, transaction
    assert_equal true, transaction.pending?
    assert_equal true, transaction.extra.dig("lunchflow", "pending")
  end

  test "stores pending false when isPending is false" do
    transaction_data = {
      id: "lf_txn_124",
      accountId: 456,
      amount: -50.00,
      currency: "USD",
      date: "2025-01-15",
      merchant: "Test Merchant",
      description: "Test transaction",
      isPending: false
    }

    result = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    transaction = result.entryable
    assert_equal false, transaction.pending?
    assert_equal false, transaction.extra.dig("lunchflow", "pending")
  end

  test "does not store pending metadata when isPending is absent" do
    transaction_data = {
      id: "lf_txn_125",
      accountId: 456,
      amount: -50.00,
      currency: "USD",
      date: "2025-01-15",
      merchant: "Test Merchant",
      description: "Test transaction"
    }

    result = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    transaction = result.entryable
    assert_not transaction.pending?
    assert_nil transaction.extra.dig("lunchflow", "pending")
    assert_nil transaction.extra.dig("lunchflow")
  end

  test "handles string true value for isPending" do
    transaction_data = {
      id: "lf_txn_126",
      accountId: 456,
      amount: -50.00,
      currency: "USD",
      date: "2025-01-15",
      merchant: "Test Merchant",
      description: "Test transaction",
      isPending: "true"
    }

    result = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    transaction = result.entryable
    assert_equal true, transaction.pending?
    assert_equal true, transaction.extra.dig("lunchflow", "pending")
  end

  test "generates temporary ID for pending transactions with blank ID" do
    transaction_data = {
      id: "",
      accountId: 456,
      amount: -50.00,
      currency: "USD",
      date: "2025-01-15",
      merchant: "Test Merchant",
      description: "Pending transaction",
      isPending: true
    }

    # Process transaction with blank ID
    result = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    transaction = result.entryable
    assert_kind_of Transaction, transaction
    assert transaction.pending?

    # Verify the entry has a generated external_id (since we can't have blank IDs)
    assert result.external_id.present?
    assert_match /^lunchflow_pending_[a-f0-9]{32}$/, result.external_id
  end

  test "does not duplicate pending transaction when synced multiple times" do
    # Create a pending transaction
    transaction_data = {
      id: "",
      accountId: 456,
      amount: -15.00,
      currency: "USD",
      date: "2025-01-15",
      merchant: "UBER",
      description: "Ride",
      isPending: true
    }

    # Process first transaction
    result1 = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result1
    transaction1 = result1.entryable
    assert transaction1.pending?
    assert_equal true, transaction1.extra.dig("lunchflow", "pending")

    # Count entries before second sync
    entries_before = @account.entries.where(source: "lunchflow").count

    # Second sync - same pending transaction (still hasn't posted)
    result2 = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result2

    # Should return the SAME entry, not create a duplicate
    assert_equal result1.id, result2.id, "Should update existing pending transaction, not create duplicate"

    # Verify no new entries were created
    entries_after = @account.entries.where(source: "lunchflow").count
    assert_equal entries_before, entries_after, "Should not create duplicate entry on re-sync"
  end

  test "does not duplicate pending transaction when user has edited it" do
    # User imports a pending transaction, then edits it (name, amount, date)
    # Next sync should update the same entry, not create a duplicate
    transaction_data = {
      id: "",
      accountId: 456,
      amount: -25.50,
      currency: "USD",
      date: "2025-01-20",
      merchant: "Coffee Shop",
      description: "Morning coffee",
      isPending: true
    }

    # First sync - import the pending transaction
    result1 = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result1
    original_external_id = result1.external_id

    # User edits the transaction (common scenario)
    result1.update!(name: "Coffee Shop Downtown", amount: 26.00)
    result1.reload

    # Verify the edits were applied
    assert_equal "Coffee Shop Downtown", result1.name
    assert_equal 26.00, result1.amount

    entries_before = @account.entries.where(source: "lunchflow").count

    # Second sync - same pending transaction data from provider (unchanged)
    result2 = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result2

    # Should return the SAME entry (same external_id, not a _1 suffix)
    assert_equal result1.id, result2.id, "Should reuse existing entry even when user edited it"
    assert_equal original_external_id, result2.external_id, "Should not create new external_id for user-edited entry"

    # Verify no duplicate was created
    entries_after = @account.entries.where(source: "lunchflow").count
    assert_equal entries_before, entries_after, "Should not create duplicate when user has edited pending transaction"
  end

  test "skips creating pending entry when posted version already exists" do
    # First sync: posted transaction arrives with real ID
    posted_transaction_data = {
      id: "lf_txn_real_123",
      accountId: 456,
      amount: -75.50,
      currency: "USD",
      date: "2025-01-20",
      merchant: "Coffee Shop",
      description: "Morning coffee",
      isPending: false
    }

    result1 = LunchflowEntry::Processor.new(
      posted_transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result1
    assert_equal "lunchflow_lf_txn_real_123", result1.external_id
    assert_not result1.entryable.pending?

    entries_before = @account.entries.where(source: "lunchflow").count

    # Second sync: pending version arrives later (without ID, so would create temp ID)
    # This should skip creation since posted version exists
    pending_transaction_data = {
      id: "", # No ID = would generate lunchflow_pending_xxx
      accountId: 456,
      amount: -75.50,
      currency: "USD",
      date: "2025-01-20", # Same date
      merchant: "Coffee Shop",
      description: "Morning coffee",
      isPending: true
    }

    result2 = LunchflowEntry::Processor.new(
      pending_transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    # Should return the existing posted entry, not create a duplicate
    assert_not_nil result2
    assert_equal result1.id, result2.id, "Should return existing posted entry"
    assert_equal "lunchflow_lf_txn_real_123", result2.external_id, "Should keep posted external_id"

    # Verify no duplicate was created
    entries_after = @account.entries.where(source: "lunchflow").count
    assert_equal entries_before, entries_after, "Should not create duplicate pending entry"
  end

  test "skips creating pending entry when posted version exists with nearby date" do
    # Posted transaction on Jan 20
    posted_transaction_data = {
      id: "lf_txn_456",
      accountId: 456,
      amount: -55.33,
      currency: "USD",
      date: "2025-01-20",
      merchant: "MORRISONS",
      description: "Groceries",
      isPending: false
    }

    result1 = LunchflowEntry::Processor.new(
      posted_transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result1

    # Pending transaction on Jan 19 (1 day earlier, within 8-day forward window)
    pending_transaction_data = {
      id: "",
      accountId: 456,
      amount: -55.33,
      currency: "USD",
      date: "2025-01-19",
      merchant: "MORRISONS",
      description: "Groceries",
      isPending: true
    }

    result2 = LunchflowEntry::Processor.new(
      pending_transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    # Should return existing posted entry (posted date is within pending date + 8 days)
    assert_equal result1.id, result2.id, "Should match posted entry with nearby date"
  end

  test "creates pending entry when merchant name doesn't match" do
    # Posted transaction at Coffee Shop
    posted_transaction_data = {
      id: "lf_txn_coffee",
      accountId: 456,
      amount: -5.00,
      currency: "USD",
      date: "2025-01-20",
      merchant: "Coffee Shop",
      description: "Latte",
      isPending: false
    }

    LunchflowEntry::Processor.new(
      posted_transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    # Pending transaction at different merchant but same amount and date
    pending_transaction_data = {
      id: "",
      accountId: 456,
      amount: -5.00, # Same amount
      currency: "USD",
      date: "2025-01-20",
      merchant: "Tea House", # Different merchant
      description: "Tea",
      isPending: true
    }

    result = LunchflowEntry::Processor.new(
      pending_transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    assert result.entryable.pending?, "Should create new pending entry when merchant doesn't match"
    assert result.external_id.start_with?("lunchflow_pending_"), "Should have temporary ID"
  end

  test "converts unix timestamp date using negative family timezone offset" do
    # 2025-07-15 01:20:00 UTC == 2025-07-14 21:20:00 EDT (UTC-4 in summer)
    # Without timezone fix this would land on July 15; with fix it lands on July 14.
    @family.update!(timezone: "America/New_York")

    transaction_data = {
      id: "lf_tz_neg_test",
      accountId: 456,
      amount: -10.00,
      currency: "USD",
      date: 1752542400, # 2025-07-15 01:20:00 UTC == 2025-07-14 21:20:00 EDT
      merchant: "Late Night Shop",
      description: "After midnight"
    }

    result = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    assert_equal Date.new(2025, 7, 14), result.date,
      "Transaction at 21:20 EDT should land on July 14, not July 15"
  end

  # --- unidentified card hold tests ---

  test "unidentified_hold? detects masked card descriptors in merchant or description only when id is blank" do
    assert LunchflowEntry::Processor.unidentified_hold?(id: nil, merchant: "474836xxxxxx6879 003015315475")
    assert LunchflowEntry::Processor.unidentified_hold?(id: "", merchant: "474836XXXXXX6879")
    assert LunchflowEntry::Processor.unidentified_hold?(merchant: "474836******6879")
    assert LunchflowEntry::Processor.unidentified_hold?(merchant: nil, description: "474836xxxxxx6879 003015315475")
    assert LunchflowEntry::Processor.unidentified_hold?(merchant: "", description: "474836xxxxxx6879")

    assert_not LunchflowEntry::Processor.unidentified_hold?(id: "lf_123", merchant: "474836xxxxxx6879 003015315475")
    assert_not LunchflowEntry::Processor.unidentified_hold?(merchant: "Uber", description: "474836xxxxxx6879")
    assert_not LunchflowEntry::Processor.unidentified_hold?(merchant: "474836xxxxxx6879", description: "Uber")
    assert_not LunchflowEntry::Processor.unidentified_hold?(merchant: "Amazon", description: "Order 123")
    assert_not LunchflowEntry::Processor.unidentified_hold?(merchant: "Card 123", description: nil)
  end

  test "does not treat masked merchant with legitimate description as unidentified hold" do
    data = {
      id: "",
      accountId: 456,
      amount: -25.00,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "474836xxxxxx6879 003015315475",
      description: "Uber Trip",
      isPending: false
    }

    result = LunchflowEntry::Processor.new(data, lunchflow_account: @lunchflow_account).process

    assert_not_nil result
    assert_equal BigDecimal("25.00"), result.amount
    assert_equal "Uber Trip", result.name
    assert_nil result.entryable.merchant, "Must not create a ProviderMerchant for a masked PAN"
    assert_equal "474836xxxxxx6879 003015315475", result.notes
    assert_not result.entryable.pending?
  end

  test "normalizes inverted positive hold amount to positive expense, suppresses merchant, and sets name" do
    # Unidentified hold returned via Lunchflow with positive amount (credit), masked card PAN
    hold_data = {
      id: "",
      accountId: 456,
      amount: 14.97, # Erroneously positive credit in Lunchflow
      currency: "EUR",
      date: "2025-01-20",
      merchant: "474836xxxxxx6879 003015315475",
      description: "474836xxxxxx6879 003015315475",
      isPending: false # Even if API returned false/missing
    }

    result = LunchflowEntry::Processor.new(
      hold_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil result
    assert_equal BigDecimal("14.97"), result.amount, "Must be positive outflow in Sure convention"
    assert_equal "Card Authorization Hold", result.name
    assert_nil result.entryable.merchant
    assert_equal "474836xxxxxx6879 003015315475", result.notes
    assert result.entryable.pending?
    assert_equal true, result.entryable.extra.dig("lunchflow", "pending")
  end

  test "claims pending hold when settled transaction arrives and skips re-importing the claimed hold on next sync" do
    # 1. Pending card hold arrives first with masked card number and inverted positive amount
    hold_data = {
      id: "",
      accountId: 456,
      amount: 14.97,
      currency: "EUR",
      date: "2025-01-19",
      merchant: "474836xxxxxx6879 003015315475",
      description: "474836xxxxxx6879 003015315475"
    }

    hold_entry = LunchflowEntry::Processor.new(
      hold_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_nil hold_entry
    assert hold_entry.entryable.pending?

    # 2. Settled transaction arrives with real merchant name "BILLA" and amount -14.97 (negative = expense in Lunchflow)
    posted_data = {
      id: "lf_txn_posted_billa",
      accountId: 456,
      amount: -14.97,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "BILLA",
      description: "Supermarket purchase",
      isPending: false
    }

    posted_entry = LunchflowEntry::Processor.new(
      posted_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_equal hold_entry.id, posted_entry.id, "Posted transaction must claim the pending hold"
    assert_equal "lunchflow_lf_txn_posted_billa", posted_entry.external_id
    assert_not posted_entry.entryable.reload.pending?

    # 3. Cached hold in raw_transactions_payload is re-processed on subsequent sync
    reprocessed_hold = LunchflowEntry::Processor.new(
      hold_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_equal posted_entry.id, reprocessed_hold.id, "Claimed hold must match the posted entry that claimed it"
    assert_equal 1, @account.entries.where(source: "lunchflow").count
  end

  test "does not skip unidentified hold when an unrelated posted purchase has the same amount and date" do
    # Unrelated posted purchase arrived first without claiming any hold
    unrelated_posted = {
      id: "lf_txn_unrelated",
      accountId: 456,
      amount: -14.97,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "BILLA",
      description: "Earlier purchase",
      isPending: false
    }

    posted_entry = LunchflowEntry::Processor.new(
      unrelated_posted,
      lunchflow_account: @lunchflow_account
    ).process

    # New unidentified hold for the same amount arrives
    hold_data = {
      id: "",
      accountId: 456,
      amount: 14.97,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "474836xxxxxx6879 003015315475",
      description: "474836xxxxxx6879 003015315475"
    }

    hold_entry = LunchflowEntry::Processor.new(
      hold_data,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_equal posted_entry.id, hold_entry.id, "Unrelated posted purchase must not suppress a new hold"
    assert hold_entry.entryable.pending?
    assert_equal 2, @account.entries.where(source: "lunchflow").count
  end

  test "find_existing_posted_version excludes pending entries that have a real provider ID" do
    # Pending entry that happened to have a real provider ID
    pending_with_id = {
      id: "lf_pending_real_id",
      accountId: 456,
      amount: -25.00,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "Coffee Shop",
      description: "Coffee",
      isPending: true
    }

    first_entry = LunchflowEntry::Processor.new(
      pending_with_id,
      lunchflow_account: @lunchflow_account
    ).process
    assert first_entry.entryable.pending?

    # Second pending entry without ID for the same merchant and amount
    pending_without_id = {
      id: "",
      accountId: 456,
      amount: -25.00,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "Coffee Shop",
      description: "Coffee",
      isPending: true
    }

    second_entry = LunchflowEntry::Processor.new(
      pending_without_id,
      lunchflow_account: @lunchflow_account
    ).process

    assert_not_equal first_entry.id, second_entry.id, "Pending entry with real ID must not be treated as a posted version"
    assert_equal 2, @account.entries.where(source: "lunchflow").count
  end

  test "captures warning DebugLogEntry when processing unidentified card hold on first import only" do
    hold_data = {
      id: "",
      accountId: 456,
      amount: 14.97,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "474836xxxxxx6879 003015315475",
      description: "474836xxxxxx6879 003015315475"
    }

    assert_difference -> { DebugLogEntry.count }, 1 do
      LunchflowEntry::Processor.new(
        hold_data,
        lunchflow_account: @lunchflow_account
      ).process
    end

    log_entry = DebugLogEntry.last
    assert_equal "provider_sync", log_entry.category
    assert_equal "warn", log_entry.level
    assert_equal "lunchflow", log_entry.provider_key
    assert_equal @lunchflow_account.current_account, log_entry.account
    assert_equal @lunchflow_account.current_account.family, log_entry.family
    assert_equal @lunchflow_account.account_provider, log_entry.account_provider
    assert_equal CardAuthorizationHold::HOLD_DIAGNOSTIC_MESSAGE, log_entry.message
    assert_equal true, log_entry.metadata["sign_inverted"]
    assert_equal "14.97", log_entry.metadata["raw_amount"]

    # Re-processing the same hold on subsequent sync does not write duplicate DebugLogEntry
    assert_no_difference -> { DebugLogEntry.count } do
      LunchflowEntry::Processor.new(
        hold_data,
        lunchflow_account: @lunchflow_account
      ).process
    end
  end

  test "captures warning DebugLogEntry with sign_inverted false for negative amount hold" do
    hold_data = {
      id: "",
      accountId: 456,
      amount: -14.97,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "474836xxxxxx6879 003015315475",
      description: "474836xxxxxx6879 003015315475"
    }

    assert_difference -> { DebugLogEntry.count }, 1 do
      LunchflowEntry::Processor.new(
        hold_data,
        lunchflow_account: @lunchflow_account
      ).process
    end

    log_entry = DebugLogEntry.last
    assert_equal false, log_entry.metadata["sign_inverted"]
    assert_equal "-14.97", log_entry.metadata["raw_amount"]
  end

  test "does not capture DebugLogEntry for regular transactions" do
    data = {
      id: "tx_regular",
      accountId: 456,
      amount: -14.97,
      currency: "EUR",
      date: "2025-01-20",
      merchant: "Uber",
      description: "Uber ride"
    }

    assert_no_difference -> { DebugLogEntry.count } do
      LunchflowEntry::Processor.new(
        data,
        lunchflow_account: @lunchflow_account
      ).process
    end
  end
end
