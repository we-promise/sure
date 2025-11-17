require "test_helper"

class Account::ProviderImportAdapterTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @adapter = Account::ProviderImportAdapter.new(@account)
    @family = families(:dylan_family)
  end

  test "imports transaction with all parameters" do
    category = categories(:income)
    merchant = ProviderMerchant.create!(
      provider_merchant_id: "test_merchant_123",
      name: "Test Merchant",
      source: "plaid"
    )

    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "plaid_test_123",
        amount: 100.50,
        currency: "USD",
        date: Date.today,
        name: "Test Transaction",
        source: "plaid",
        category_id: category.id,
        merchant: merchant
      )

      assert_equal 100.50, entry.amount
      assert_equal "USD", entry.currency
      assert_equal Date.today, entry.date
      assert_equal "Test Transaction", entry.name
      assert_equal category.id, entry.transaction.category_id
      assert_equal merchant.id, entry.transaction.merchant_id
    end
  end

  test "imports transaction with minimal parameters" do
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "simplefin_abc",
        amount: 50.00,
        currency: "USD",
        date: Date.today,
        name: "Simple Transaction",
        source: "simplefin"
      )

      assert_equal 50.00, entry.amount
      assert_equal "simplefin_abc", entry.external_id
      assert_equal "simplefin", entry.source
      assert_nil entry.transaction.category_id
      assert_nil entry.transaction.merchant_id
    end
  end

  test "updates existing transaction instead of creating duplicate" do
    # Create initial transaction
    entry = @adapter.import_transaction(
      external_id: "plaid_duplicate_test",
      amount: 100.00,
      currency: "USD",
      date: Date.today,
      name: "Original Name",
      source: "plaid"
    )

    # Import again with different data - should update, not create new
    assert_no_difference "@account.entries.count" do
      updated_entry = @adapter.import_transaction(
        external_id: "plaid_duplicate_test",
        amount: 200.00,
        currency: "USD",
        date: Date.today,
        name: "Updated Name",
        source: "plaid"
      )

      assert_equal entry.id, updated_entry.id
      assert_equal 200.00, updated_entry.amount
      assert_equal "Updated Name", updated_entry.name
    end
  end

  test "allows same external_id from different sources without collision" do
    # Create transaction from SimpleFin with ID "transaction_123"
    simplefin_entry = @adapter.import_transaction(
      external_id: "transaction_123",
      amount: 100.00,
      currency: "USD",
      date: Date.today,
      name: "SimpleFin Transaction",
      source: "simplefin"
    )

    # Create transaction from Plaid with same ID "transaction_123" - should NOT collide
    # because external_id is unique per (account, source) combination
    assert_difference "@account.entries.count", 1 do
      plaid_entry = @adapter.import_transaction(
        external_id: "transaction_123",
        amount: 200.00,
        currency: "USD",
        date: Date.today,
        name: "Plaid Transaction",
        source: "plaid"
      )

      # Should be different entries
      assert_not_equal simplefin_entry.id, plaid_entry.id
      assert_equal "simplefin", simplefin_entry.source
      assert_equal "plaid", plaid_entry.source
      assert_equal "transaction_123", simplefin_entry.external_id
      assert_equal "transaction_123", plaid_entry.external_id
    end
  end

  test "raises error when external_id is missing" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_transaction(
        external_id: "",
        amount: 100.00,
        currency: "USD",
        date: Date.today,
        name: "Test",
        source: "plaid"
      )
    end

    assert_equal "external_id is required", exception.message
  end

  test "raises error when source is missing" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_transaction(
        external_id: "test_123",
        amount: 100.00,
        currency: "USD",
        date: Date.today,
        name: "Test",
        source: ""
      )
    end

    assert_equal "source is required", exception.message
  end

  test "finds or creates merchant with all data" do
    assert_difference "ProviderMerchant.count", 1 do
      merchant = @adapter.find_or_create_merchant(
        provider_merchant_id: "plaid_merchant_123",
        name: "Test Merchant",
        source: "plaid",
        website_url: "https://example.com",
        logo_url: "https://example.com/logo.png"
      )

      assert_equal "Test Merchant", merchant.name
      assert_equal "plaid", merchant.source
      assert_equal "plaid_merchant_123", merchant.provider_merchant_id
      assert_equal "https://example.com", merchant.website_url
      assert_equal "https://example.com/logo.png", merchant.logo_url
    end
  end

  test "returns nil when merchant data is insufficient" do
    merchant = @adapter.find_or_create_merchant(
      provider_merchant_id: "",
      name: "",
      source: "plaid"
    )

    assert_nil merchant
  end

  test "finds existing merchant instead of creating duplicate" do
    existing_merchant = ProviderMerchant.create!(
      provider_merchant_id: "existing_123",
      name: "Existing Merchant",
      source: "plaid"
    )

    assert_no_difference "ProviderMerchant.count" do
      merchant = @adapter.find_or_create_merchant(
        provider_merchant_id: "existing_123",
        name: "Existing Merchant",
        source: "plaid"
      )

      assert_equal existing_merchant.id, merchant.id
    end
  end

  test "updates account balance" do
    @adapter.update_balance(
      balance: 5000.00,
      cash_balance: 4500.00,
      source: "plaid"
    )

    @account.reload
    assert_equal 5000.00, @account.balance
    assert_equal 4500.00, @account.cash_balance
  end

  test "updates account balance without cash_balance" do
    @adapter.update_balance(
      balance: 3000.00,
      source: "simplefin"
    )

    @account.reload
    assert_equal 3000.00, @account.balance
    assert_equal 3000.00, @account.cash_balance
  end

  test "imports holding with all parameters" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Use a date that doesn't conflict with fixtures (fixtures use today and 1.day.ago)
    holding_date = Date.today - 2.days

    assert_difference "investment_account.holdings.count", 1 do
      holding = adapter.import_holding(
        security: security,
        quantity: 10.5,
        amount: 1575.00,
        currency: "USD",
        date: holding_date,
        price: 150.00,
        source: "plaid"
      )

      assert_equal security.id, holding.security_id
      assert_equal 10.5, holding.qty
      assert_equal 1575.00, holding.amount
      assert_equal 150.00, holding.price
      assert_equal holding_date, holding.date
    end
  end

  test "raises error when security is missing for holding import" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_holding(
        security: nil,
        quantity: 10,
        amount: 1000,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )
    end

    assert_equal "security is required", exception.message
  end

  test "imports trade with all parameters" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    assert_difference "investment_account.entries.count", 1 do
      entry = adapter.import_trade(
        security: security,
        quantity: 5,
        price: 150.00,
        amount: 750.00,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )

      assert_kind_of Trade, entry.entryable
      assert_equal 5, entry.entryable.qty
      assert_equal 150.00, entry.entryable.price
      assert_equal 750.00, entry.amount
      assert_match(/Buy.*5.*shares/i, entry.name)
    end
  end

  test "raises error when security is missing for trade import" do
    exception = assert_raises(ArgumentError) do
      @adapter.import_trade(
        security: nil,
        quantity: 5,
        price: 100,
        amount: 500,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )
    end

    assert_equal "security is required", exception.message
  end

  test "stores account_provider_id when importing holding" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)
    account_provider = AccountProvider.create!(
      account: investment_account,
      provider: plaid_accounts(:one)
    )

    holding = adapter.import_holding(
      security: security,
      quantity: 10,
      amount: 1500,
      currency: "USD",
      date: Date.today - 10.days,
      price: 150,
      source: "plaid",
      account_provider_id: account_provider.id
    )

    assert_equal account_provider.id, holding.account_provider_id
  end

  test "does not delete future holdings when can_delete_holdings? returns false" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a future holding
    future_holding = investment_account.holdings.create!(
      security: security,
      qty: 5,
      amount: 750,
      currency: "USD",
      date: Date.today + 30.days,
      price: 150
    )

    # Mock can_delete_holdings? to return false
    investment_account.expects(:can_delete_holdings?).returns(false)

    # Import a holding with delete_future_holdings flag
    adapter.import_holding(
      security: security,
      quantity: 10,
      amount: 1500,
      currency: "USD",
      date: Date.today,
      price: 150,
      source: "plaid",
      delete_future_holdings: true
    )

    # Future holding should still exist
    assert Holding.exists?(future_holding.id)
  end

  test "deletes only holdings from same provider when account_provider_id is provided" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create an account provider
    plaid_account = PlaidAccount.create!(
      current_balance: 1000,
      available_balance: 1000,
      currency: "USD",
      name: "Test Plaid Account",
      plaid_item: plaid_items(:one),
      plaid_id: "acc_mock_test_1",
      plaid_type: "investment",
      plaid_subtype: "brokerage"
    )

    provider = AccountProvider.create!(
      account: investment_account,
      provider: plaid_account
    )

    # Create future holdings - one from the provider, one without a provider
    future_holding_with_provider = investment_account.holdings.create!(
      security: security,
      qty: 5,
      amount: 750,
      currency: "USD",
      date: Date.today + 120.days,
      price: 150,
      account_provider_id: provider.id
    )

    future_holding_without_provider = investment_account.holdings.create!(
      security: security,
      qty: 3,
      amount: 450,
      currency: "USD",
      date: Date.today + 2.days,
      price: 150,
      account_provider_id: nil
    )

    # Mock can_delete_holdings? to return true
    investment_account.expects(:can_delete_holdings?).returns(true)

    # Import a holding with provider ID and delete_future_holdings flag
    adapter.import_holding(
      security: security,
      quantity: 10,
      amount: 1500,
      currency: "USD",
      date: Date.today - 10.days,
      price: 150,
      source: "plaid",
      account_provider_id: provider.id,
      delete_future_holdings: true
    )

    # Only the holding from the same provider should be deleted
    assert_not Holding.exists?(future_holding_with_provider.id)
    assert Holding.exists?(future_holding_without_provider.id)
  end

  test "deletes all future holdings when account_provider_id is not provided and can_delete_holdings? returns true" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create two future holdings
    future_holding_1 = investment_account.holdings.create!(
      security: security,
      qty: 5,
      amount: 750,
      currency: "USD",
      date: Date.today + 121.days,
      price: 150
    )

    future_holding_2 = investment_account.holdings.create!(
      security: security,
      qty: 3,
      amount: 450,
      currency: "USD",
      date: Date.today + 2.days,
      price: 150
    )

    # Mock can_delete_holdings? to return true
    investment_account.expects(:can_delete_holdings?).returns(true)

    # Import a holding without account_provider_id
    adapter.import_holding(
      security: security,
      quantity: 10,
      amount: 1500,
      currency: "USD",
      date: Date.today,
      price: 150,
      source: "plaid",
      delete_future_holdings: true
    )

    # All future holdings should be deleted
    assert_not Holding.exists?(future_holding_1.id)
    assert_not Holding.exists?(future_holding_2.id)
  end

  test "updates existing trade attributes instead of keeping stale data" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    aapl = securities(:aapl)
    msft = securities(:msft)

    # Create initial trade
    entry = adapter.import_trade(
      external_id: "plaid_trade_123",
      security: aapl,
      quantity: 5,
      price: 150.00,
      amount: 750.00,
      currency: "USD",
      date: Date.today,
      source: "plaid"
    )

    # Import again with updated attributes - should update Trade, not keep stale data
    assert_no_difference "investment_account.entries.count" do
      updated_entry = adapter.import_trade(
        external_id: "plaid_trade_123",
        security: msft,
        quantity: 10,
        price: 200.00,
        amount: 2000.00,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )

      assert_equal entry.id, updated_entry.id
      # Trade attributes should be updated
      assert_equal msft.id, updated_entry.entryable.security_id
      assert_equal 10, updated_entry.entryable.qty
      assert_equal 200.00, updated_entry.entryable.price
      assert_equal "USD", updated_entry.entryable.currency
      # Entry attributes should also be updated
      assert_equal 2000.00, updated_entry.amount
    end
  end

  test "raises error when external_id collision occurs across different entryable types for transaction" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a trade with external_id "collision_test"
    adapter.import_trade(
      external_id: "collision_test",
      security: security,
      quantity: 5,
      price: 150.00,
      amount: 750.00,
      currency: "USD",
      date: Date.today,
      source: "plaid"
    )

    # Try to create a transaction with the same external_id and source
    exception = assert_raises(ArgumentError) do
      adapter.import_transaction(
        external_id: "collision_test",
        amount: 100.00,
        currency: "USD",
        date: Date.today,
        name: "Test Transaction",
        source: "plaid"
      )
    end

    assert_match(/Entry with external_id.*already exists with different entryable type/i, exception.message)
  end

  test "raises error when external_id collision occurs across different entryable types for trade" do
    investment_account = accounts(:investment)
    adapter = Account::ProviderImportAdapter.new(investment_account)
    security = securities(:aapl)

    # Create a transaction with external_id "collision_test_2"
    adapter.import_transaction(
      external_id: "collision_test_2",
      amount: 100.00,
      currency: "USD",
      date: Date.today,
      name: "Test Transaction",
      source: "plaid"
    )

    # Try to create a trade with the same external_id and source
    exception = assert_raises(ArgumentError) do
      adapter.import_trade(
        external_id: "collision_test_2",
        security: security,
        quantity: 5,
        price: 150.00,
        amount: 750.00,
        currency: "USD",
        date: Date.today,
        source: "plaid"
      )
    end

    assert_match(/Entry with external_id.*already exists with different entryable type/i, exception.message)
  end

  test "claims manual transaction when provider syncs matching transaction" do
    # Create a manual transaction (no external_id or source)
    manual_entry = @account.entries.create!(
      date: Date.today,
      amount: 42.50,
      currency: "USD",
      name: "Coffee Shop",
      entryable: Transaction.new
    )

    assert_nil manual_entry.external_id
    assert_nil manual_entry.source

    # Provider syncs a matching transaction - should claim the manual entry, not create new
    assert_no_difference "@account.entries.count" do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_12345",
        amount: 42.50,
        currency: "USD",
        date: Date.today,
        name: "Coffee Shop - Lunchflow",
        source: "lunchflow"
      )

      # Should be the same entry, now claimed by the provider
      assert_equal manual_entry.id, entry.id
      assert_equal "lunchflow_12345", entry.external_id
      assert_equal "lunchflow", entry.source
      assert_equal "Coffee Shop - Lunchflow", entry.name
    end
  end

  test "claims CSV imported transaction when provider syncs matching transaction" do
    # Create a CSV imported transaction (has import_id but no external_id)
    import = Import.create!(
      family: @family,
      type: "TransactionImport",
      status: :complete
    )

    csv_entry = @account.entries.create!(
      date: Date.today - 1.day,
      amount: 125.00,
      currency: "USD",
      name: "Grocery Store",
      import: import,
      entryable: Transaction.new
    )

    assert_nil csv_entry.external_id
    assert_nil csv_entry.source
    assert_equal import.id, csv_entry.import_id

    # Provider syncs a matching transaction - should claim the CSV entry
    assert_no_difference "@account.entries.count" do
      entry = @adapter.import_transaction(
        external_id: "plaid_csv_match",
        amount: 125.00,
        currency: "USD",
        date: Date.today - 1.day,
        name: "Grocery Store - Plaid",
        source: "plaid"
      )

      # Should be the same entry, now claimed by the provider
      assert_equal csv_entry.id, entry.id
      assert_equal "plaid_csv_match", entry.external_id
      assert_equal "plaid", entry.source
      assert_equal import.id, entry.import_id # Should preserve the import_id
    end
  end

  test "does not claim transaction when date does not match" do
    # Create a manual transaction
    manual_entry = @account.entries.create!(
      date: Date.today - 5.days,
      amount: 50.00,
      currency: "USD",
      name: "Restaurant",
      entryable: Transaction.new
    )

    # Provider syncs similar transaction but different date - should create new entry
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_different_date",
        amount: 50.00,
        currency: "USD",
        date: Date.today,
        name: "Restaurant",
        source: "lunchflow"
      )

      # Should be a different entry
      assert_not_equal manual_entry.id, entry.id
    end
  end

  test "does not claim transaction when amount does not match" do
    # Create a manual transaction
    manual_entry = @account.entries.create!(
      date: Date.today,
      amount: 50.00,
      currency: "USD",
      name: "Restaurant",
      entryable: Transaction.new
    )

    # Provider syncs similar transaction but different amount - should create new entry
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_different_amount",
        amount: 51.00,
        currency: "USD",
        date: Date.today,
        name: "Restaurant",
        source: "lunchflow"
      )

      # Should be a different entry
      assert_not_equal manual_entry.id, entry.id
    end
  end

  test "does not claim transaction when currency does not match" do
    # Create a manual transaction
    manual_entry = @account.entries.create!(
      date: Date.today,
      amount: 50.00,
      currency: "EUR",
      name: "Restaurant",
      entryable: Transaction.new
    )

    # Provider syncs similar transaction but different currency - should create new entry
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_different_currency",
        amount: 50.00,
        currency: "USD",
        date: Date.today,
        name: "Restaurant",
        source: "lunchflow"
      )

      # Should be a different entry
      assert_not_equal manual_entry.id, entry.id
    end
  end

  test "does not claim transaction that already has external_id from different provider" do
    # Create a transaction already synced from SimpleFin
    simplefin_entry = @adapter.import_transaction(
      external_id: "simplefin_123",
      amount: 30.00,
      currency: "USD",
      date: Date.today,
      name: "Gas Station",
      source: "simplefin"
    )

    # Provider (Lunchflow) syncs matching transaction - should create new entry, not claim SimpleFin's
    assert_difference "@account.entries.count", 1 do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_gas",
        amount: 30.00,
        currency: "USD",
        date: Date.today,
        name: "Gas Station",
        source: "lunchflow"
      )

      # Should be a different entry because SimpleFin already claimed it
      assert_not_equal simplefin_entry.id, entry.id
      assert_equal "lunchflow", entry.source
      assert_equal "simplefin", simplefin_entry.reload.source
    end
  end

  test "claims oldest matching manual transaction when multiple exist" do
    # Create multiple manual transactions with same date, amount, currency
    older_entry = @account.entries.create!(
      date: Date.today,
      amount: 20.00,
      currency: "USD",
      name: "Parking - Old",
      entryable: Transaction.new,
      created_at: 2.hours.ago
    )

    newer_entry = @account.entries.create!(
      date: Date.today,
      amount: 20.00,
      currency: "USD",
      name: "Parking - New",
      entryable: Transaction.new,
      created_at: 1.hour.ago
    )

    # Provider syncs matching transaction - should claim the oldest one
    assert_no_difference "@account.entries.count" do
      entry = @adapter.import_transaction(
        external_id: "lunchflow_parking",
        amount: 20.00,
        currency: "USD",
        date: Date.today,
        name: "Parking - Provider",
        source: "lunchflow"
      )

      # Should claim the older entry
      assert_equal older_entry.id, entry.id
      assert_equal "lunchflow_parking", entry.external_id

      # Newer entry should remain unclaimed
      assert_nil newer_entry.reload.external_id
    end
  end
end
