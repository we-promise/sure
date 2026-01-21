require "test_helper"

class LunchflowEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = @family.users.first
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

    # Process same transaction again - should find existing by external_id and update
    result2 = LunchflowEntry::Processor.new(
      transaction_data,
      lunchflow_account: @lunchflow_account
    ).process

    # Should be the same entry (update, not duplicate)
    assert_equal result.id, result2.id
    assert_equal result.external_id, result2.external_id
  end
end
