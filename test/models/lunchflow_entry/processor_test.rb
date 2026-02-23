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
end
