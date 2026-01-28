require "test_helper"

class LunchflowItem::ImporterBlankIdTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = LunchflowItem.create!(
      family: @family,
      name: "Test Lunchflow",
      api_key: "test_key_123",
      status: :good
    )
    @lunchflow_account = @item.lunchflow_accounts.create!(
      account_id: "test_account_123",
      name: "Test Account",
      currency: "GBP"
    )
    @sure_account = @family.accounts.create!(
      name: "Test Account",
      balance: 1000,
      currency: "GBP",
      accountable: Depository.new(subtype: "checking")
    )
    AccountProvider.create!(
      account: @sure_account,
      provider: @lunchflow_account
    )
    @lunchflow_account.reload
  end

  test "prevents unbounded growth when same blank-ID transaction synced multiple times" do
    # Simulate a pending transaction with blank ID that Lunchflow keeps returning
    pending_transaction = {
      "id" => "",
      "accountId" => @lunchflow_account.account_id,
      "amount" => -15.50,
      "currency" => "GBP",
      "date" => Date.today.to_s,
      "merchant" => "UBER",
      "description" => "Ride to office",
      "isPending" => true
    }

    # Mock the API to return this transaction
    mock_provider = mock()
    mock_provider.stubs(:get_account_transactions)
      .with(@lunchflow_account.account_id, anything)
      .returns({
        transactions: [ pending_transaction ],
        count: 1
      })
    mock_provider.stubs(:get_account_balance)
      .with(@lunchflow_account.account_id)
      .returns({ balance: 100.0, currency: "GBP" })

    # First sync - should store the transaction
    importer = LunchflowItem::Importer.new(@item, lunchflow_provider: mock_provider)
    result = importer.send(:fetch_and_store_transactions, @lunchflow_account)

    assert result[:success]
    first_payload_size = @lunchflow_account.reload.raw_transactions_payload.size
    assert_equal 1, first_payload_size, "First sync should store 1 transaction"

    # Second sync - same transaction returned again
    # Without fix: would append again (size = 2)
    # With fix: should detect duplicate via content hash (size = 1)
    result = importer.send(:fetch_and_store_transactions, @lunchflow_account)

    assert result[:success]
    second_payload_size = @lunchflow_account.reload.raw_transactions_payload.size
    assert_equal 1, second_payload_size, "Second sync should NOT append duplicate blank-ID transaction"

    # Third sync - verify it stays at 1
    result = importer.send(:fetch_and_store_transactions, @lunchflow_account)

    assert result[:success]
    third_payload_size = @lunchflow_account.reload.raw_transactions_payload.size
    assert_equal 1, third_payload_size, "Third sync should NOT append duplicate blank-ID transaction"
  end

  test "allows multiple DISTINCT blank-ID transactions to be stored" do
    # Two different pending transactions, both with blank IDs
    transaction1 = {
      "id" => "",
      "accountId" => @lunchflow_account.account_id,
      "amount" => -10.00,
      "currency" => "GBP",
      "date" => Date.today.to_s,
      "merchant" => "UBER",
      "description" => "Morning ride",
      "isPending" => true
    }

    transaction2 = {
      "id" => "",
      "accountId" => @lunchflow_account.account_id,
      "amount" => -15.50,
      "currency" => "GBP",
      "date" => Date.today.to_s,
      "merchant" => "UBER",
      "description" => "Evening ride",  # Different description
      "isPending" => true
    }

    # First sync with transaction1
    mock_provider = mock()
    mock_provider.stubs(:get_account_transactions)
      .with(@lunchflow_account.account_id, anything)
      .returns({
        transactions: [ transaction1 ],
        count: 1
      })
    mock_provider.stubs(:get_account_balance)
      .with(@lunchflow_account.account_id)
      .returns({ balance: 100.0, currency: "GBP" })

    importer = LunchflowItem::Importer.new(@item, lunchflow_provider: mock_provider)
    result = importer.send(:fetch_and_store_transactions, @lunchflow_account)

    assert result[:success]
    assert_equal 1, @lunchflow_account.reload.raw_transactions_payload.size

    # Second sync with BOTH transactions
    mock_provider.stubs(:get_account_transactions)
      .with(@lunchflow_account.account_id, anything)
      .returns({
        transactions: [ transaction1, transaction2 ],
        count: 2
      })

    result = importer.send(:fetch_and_store_transactions, @lunchflow_account)

    assert result[:success]
    payload = @lunchflow_account.reload.raw_transactions_payload
    assert_equal 2, payload.size, "Should store both distinct transactions despite blank IDs"

    # Verify both transactions are different
    descriptions = payload.map { |tx| tx.with_indifferent_access[:description] }
    assert_includes descriptions, "Morning ride"
    assert_includes descriptions, "Evening ride"
  end

  test "content hash uses same attributes as processor for consistency" do
    pending_transaction = {
      "id" => "",
      "accountId" => @lunchflow_account.account_id,
      "amount" => -10.00,
      "currency" => "GBP",
      "date" => Date.today.to_s,
      "merchant" => "TEST",
      "description" => "Test transaction",
      "isPending" => true
    }

    # Store the transaction
    @lunchflow_account.upsert_lunchflow_transactions_snapshot!([ pending_transaction ])

    # Process it through the processor to generate external_id
    processor = LunchflowEntry::Processor.new(
      pending_transaction.with_indifferent_access,
      lunchflow_account: @lunchflow_account
    )
    processor.process

    # Check that the entry was created
    entry = @sure_account.entries.last
    assert entry.present?
    assert entry.external_id.start_with?("lunchflow_pending_")

    # Extract the hash from the external_id (remove prefix and any collision suffix)
    external_id_hash = entry.external_id.sub("lunchflow_pending_", "").split("_").first

    # Generate content hash using importer method
    mock_provider = mock()
    importer = LunchflowItem::Importer.new(@item, lunchflow_provider: mock_provider)
    content_hash = importer.send(:content_hash_for_transaction, pending_transaction.with_indifferent_access)

    # They should match (processor adds prefix, importer is just the hash)
    assert_equal content_hash, external_id_hash, "Importer content hash should match processor's MD5 hash"
  end

  test "transactions with IDs are not affected by content hash logic" do
    # Transaction with a proper ID
    transaction_with_id = {
      "id" => "txn_123",
      "accountId" => @lunchflow_account.account_id,
      "amount" => -20.00,
      "currency" => "GBP",
      "date" => Date.today.to_s,
      "merchant" => "TESCO",
      "description" => "Groceries",
      "isPending" => false
    }

    # Sync twice - should only store once based on ID
    mock_provider = mock()
    mock_provider.stubs(:get_account_transactions)
      .with(@lunchflow_account.account_id, anything)
      .returns({
        transactions: [ transaction_with_id ],
        count: 1
      })
    mock_provider.stubs(:get_account_balance)
      .with(@lunchflow_account.account_id)
      .returns({ balance: 100.0, currency: "GBP" })

    importer = LunchflowItem::Importer.new(@item, lunchflow_provider: mock_provider)

    # First sync
    result = importer.send(:fetch_and_store_transactions, @lunchflow_account)
    assert result[:success]
    assert_equal 1, @lunchflow_account.reload.raw_transactions_payload.size

    # Second sync - should not duplicate
    result = importer.send(:fetch_and_store_transactions, @lunchflow_account)
    assert result[:success]
    assert_equal 1, @lunchflow_account.reload.raw_transactions_payload.size
  end
end
