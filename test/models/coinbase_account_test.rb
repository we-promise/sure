require "test_helper"

class CoinbaseAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinbase_item = CoinbaseItem.create!(
      family: @family,
      name: "Test Coinbase",
      api_key: "test_key",
      api_secret: "test_secret"
    )
    @coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "Bitcoin Wallet",
      account_id: "cb_btc_123",
      currency: "BTC",
      current_balance: 0.5
    )
  end

  test "belongs to coinbase_item" do
    assert_equal @coinbase_item, @coinbase_account.coinbase_item
  end

  test "validates presence of name" do
    account = CoinbaseAccount.new(coinbase_item: @coinbase_item, currency: "BTC")
    assert_not account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  test "validates presence of currency" do
    account = CoinbaseAccount.new(coinbase_item: @coinbase_item, name: "Test")
    assert_not account.valid?
    assert_includes account.errors[:currency], "can't be blank"
  end

  test "upsert_coinbase_snapshot! updates account data" do
    snapshot = {
      "id" => "new_account_id",
      "name" => "Updated Wallet",
      "balance" => 1.5,
      "status" => "active",
      "currency" => "BTC"
    }

    @coinbase_account.upsert_coinbase_snapshot!(snapshot)

    assert_equal "new_account_id", @coinbase_account.account_id
    assert_equal "Updated Wallet", @coinbase_account.name
    assert_equal 1.5, @coinbase_account.current_balance
    assert_equal "active", @coinbase_account.account_status
  end

  test "upsert_coinbase_transactions_snapshot! stores transaction data" do
    transactions = {
      "transactions" => [
        { "id" => "tx1", "type" => "buy", "amount" => { "amount" => "0.1", "currency" => "BTC" } }
      ]
    }

    @coinbase_account.upsert_coinbase_transactions_snapshot!(transactions)

    assert_equal transactions, @coinbase_account.raw_transactions_payload
  end

  test "current_account returns nil when no account_provider exists" do
    assert_nil @coinbase_account.current_account
  end

  test "current_account returns linked account when account_provider exists" do
    account = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: @coinbase_account)

    # Reload to pick up the association
    @coinbase_account.reload

    assert_equal account, @coinbase_account.current_account
  end

  test "ensure_account_provider! creates provider link" do
    account = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    assert_difference "AccountProvider.count", 1 do
      @coinbase_account.ensure_account_provider!(account)
    end

    @coinbase_account.reload
    assert_equal account, @coinbase_account.current_account
  end

  test "ensure_account_provider! updates existing link" do
    account1 = Account.create!(
      family: @family,
      name: "Coinbase BTC 1",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    account2 = Account.create!(
      family: @family,
      name: "Coinbase BTC 2",
      balance: 60000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    @coinbase_account.ensure_account_provider!(account1)
    @coinbase_account.reload

    assert_equal account1, @coinbase_account.current_account

    # Now link to a different account
    assert_no_difference "AccountProvider.count" do
      @coinbase_account.ensure_account_provider!(account2)
    end

    @coinbase_account.reload
    assert_equal account2, @coinbase_account.current_account
  end
end
