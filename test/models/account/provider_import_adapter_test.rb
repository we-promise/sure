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

    # Create transaction from Plaid with same ID "transaction_123" - should not collide
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
end
