require "test_helper"

class CoinstatsAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
    @coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Test Wallet",
      currency: "USD",
      current_balance: 1000.00
    )
  end

  test "belongs to coinstats_item" do
    assert_equal @coinstats_item, @coinstats_account.coinstats_item
  end

  test "can have account through account_provider" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Linked Crypto Account",
      balance: 1000,
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: @coinstats_account)

    assert_equal account, @coinstats_account.account
    assert_equal account, @coinstats_account.current_account
  end

  test "requires name to be present" do
    coinstats_account = @coinstats_item.coinstats_accounts.build(
      currency: "USD"
    )
    coinstats_account.name = nil

    assert_not coinstats_account.valid?
    assert_includes coinstats_account.errors[:name], "can't be blank"
  end

  test "requires currency to be present" do
    coinstats_account = @coinstats_item.coinstats_accounts.build(
      name: "Test"
    )
    coinstats_account.currency = nil

    assert_not coinstats_account.valid?
    assert_includes coinstats_account.errors[:currency], "can't be blank"
  end

  test "account_id is unique per coinstats_item" do
    @coinstats_account.update!(account_id: "unique_account_id_123")

    duplicate = @coinstats_item.coinstats_accounts.build(
      name: "Duplicate",
      currency: "USD",
      account_id: "unique_account_id_123"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:account_id], "has already been taken"
  end

  test "allows nil account_id for multiple accounts" do
    second_account = @coinstats_item.coinstats_accounts.build(
      name: "Second Account",
      currency: "USD",
      account_id: nil
    )

    assert second_account.valid?
  end

  test "upsert_coinstats_snapshot updates balance and metadata" do
    snapshot = {
      balance: 2500.50,
      currency: "USD",
      name: "Updated Wallet Name",
      status: "active",
      provider: "coinstats",
      institution_logo: "https://example.com/logo.png"
    }

    @coinstats_account.upsert_coinstats_snapshot!(snapshot)
    @coinstats_account.reload

    assert_equal BigDecimal("2500.50"), @coinstats_account.current_balance
    assert_equal "USD", @coinstats_account.currency
    assert_equal "Updated Wallet Name", @coinstats_account.name
    assert_equal "active", @coinstats_account.account_status
    assert_equal "coinstats", @coinstats_account.provider
    assert_equal({ "logo" => "https://example.com/logo.png" }, @coinstats_account.institution_metadata)
    assert_equal snapshot.stringify_keys, @coinstats_account.raw_payload
  end

  test "upsert_coinstats_snapshot handles symbol keys" do
    snapshot = {
      balance: 3000.0,
      currency: "USD",
      name: "Symbol Key Wallet"
    }

    @coinstats_account.upsert_coinstats_snapshot!(snapshot)
    @coinstats_account.reload

    assert_equal BigDecimal("3000.0"), @coinstats_account.current_balance
    assert_equal "Symbol Key Wallet", @coinstats_account.name
  end

  test "upsert_coinstats_snapshot handles string keys" do
    snapshot = {
      "balance" => 3500.0,
      "currency" => "USD",
      "name" => "String Key Wallet"
    }

    @coinstats_account.upsert_coinstats_snapshot!(snapshot)
    @coinstats_account.reload

    assert_equal BigDecimal("3500.0"), @coinstats_account.current_balance
    assert_equal "String Key Wallet", @coinstats_account.name
  end

  test "upsert_coinstats_snapshot sets account_id from id if not already set" do
    @coinstats_account.update!(account_id: nil)

    snapshot = {
      id: "new_token_id_123",
      balance: 1000.0,
      currency: "USD",
      name: "Test"
    }

    @coinstats_account.upsert_coinstats_snapshot!(snapshot)
    @coinstats_account.reload

    assert_equal "new_token_id_123", @coinstats_account.account_id
  end

  test "upsert_coinstats_snapshot preserves existing account_id" do
    @coinstats_account.update!(account_id: "existing_id")

    snapshot = {
      id: "different_id",
      balance: 1000.0,
      currency: "USD",
      name: "Test"
    }

    @coinstats_account.upsert_coinstats_snapshot!(snapshot)
    @coinstats_account.reload

    assert_equal "existing_id", @coinstats_account.account_id
  end

  test "upsert_coinstats_transactions_snapshot stores transactions array" do
    transactions = [
      { type: "Received", date: "2025-01-01T10:00:00.000Z", hash: { id: "0xabc" } },
      { type: "Sent", date: "2025-01-02T11:00:00.000Z", hash: { id: "0xdef" } }
    ]

    @coinstats_account.upsert_coinstats_transactions_snapshot!(transactions)
    @coinstats_account.reload

    assert_equal 2, @coinstats_account.raw_transactions_payload.count
    # Keys may be strings after DB round-trip
    first_tx = @coinstats_account.raw_transactions_payload.first
    assert_equal "0xabc", first_tx.dig("hash", "id") || first_tx.dig(:hash, :id)
  end

  test "upsert_coinstats_transactions_snapshot extracts result from hash response" do
    response = {
      meta: { page: 1, limit: 100 },
      result: [
        { type: "Received", date: "2025-01-01T10:00:00.000Z", hash: { id: "0xabc" } }
      ]
    }

    @coinstats_account.upsert_coinstats_transactions_snapshot!(response)
    @coinstats_account.reload

    assert_equal 1, @coinstats_account.raw_transactions_payload.count
    assert_equal "0xabc", @coinstats_account.raw_transactions_payload.first["hash"]["id"].to_s
  end

  test "upsert_coinstats_transactions_snapshot handles empty result" do
    response = {
      meta: { page: 1, limit: 100 },
      result: []
    }

    @coinstats_account.upsert_coinstats_transactions_snapshot!(response)
    @coinstats_account.reload

    assert_equal [], @coinstats_account.raw_transactions_payload
  end
end
