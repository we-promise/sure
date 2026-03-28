require "test_helper"

class BinanceAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @binance_item = BinanceItem.create!(
      family: @family,
      name: "Test Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
    @binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD",
      current_balance: 1000
    )
  end

  test "belongs to binance_item" do
    assert_equal @binance_item, @binance_account.binance_item
  end

  test "validates presence of name" do
    account = BinanceAccount.new(binance_item: @binance_item, currency: "USD")
    refute account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  test "validates presence of currency" do
    account = BinanceAccount.new(binance_item: @binance_item, name: "Test")
    refute account.valid?
    assert_includes account.errors[:currency], "can't be blank"
  end

  test "upsert_from_binance! updates account data" do
    snapshot = {
      account_id: "new_uid",
      name: "Updated Binance Spot",
      currency: "USD",
      current_balance: 2500,
      cash_balance: 0,
      status: "active",
      account_type: "spot",
      provider: "binance",
      institution_metadata: { "name" => "Binance" },
      raw_payload: { "uid" => "new_uid" },
      raw_holdings_payload: [ { "asset" => "BTC", "quantity" => "0.1" } ]
    }

    @binance_account.upsert_from_binance!(snapshot)

    assert_equal "new_uid", @binance_account.account_id
    assert_equal "Updated Binance Spot", @binance_account.name
    assert_equal 2500, @binance_account.current_balance
    assert_equal "active", @binance_account.account_status
    assert_equal [ { "asset" => "BTC", "quantity" => "0.1" } ], @binance_account.raw_holdings_payload
  end

  test "upsert_transactions_snapshot! stores transaction data" do
    transactions = { "trades" => [ { "id" => 1 } ] }

    @binance_account.upsert_transactions_snapshot!(transactions)

    assert_equal transactions, @binance_account.raw_transactions_payload
  end

  test "current_account returns linked account when present" do
    account = Account.create!(
      family: @family,
      name: "Linked Binance",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: @binance_account)

    @binance_account.reload
    assert_equal account, @binance_account.current_account
  end

  test "ensure_account_provider! creates provider link" do
    account = Account.create!(
      family: @family,
      name: "Manual Binance",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    assert_difference "AccountProvider.count", 1 do
      @binance_account.ensure_account_provider!(account)
    end

    @binance_account.reload
    assert_equal account, @binance_account.current_account
  end

  test "ensure_account_provider! updates existing provider link" do
    account1 = Account.create!(
      family: @family,
      name: "First Account",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    account2 = Account.create!(
      family: @family,
      name: "Second Account",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    @binance_account.ensure_account_provider!(account1)
    @binance_account.reload
    assert_equal account1, @binance_account.current_account

    assert_no_difference "AccountProvider.count" do
      @binance_account.ensure_account_provider!(account2)
    end

    @binance_account.reload
    assert_equal account2, @binance_account.current_account
  end
end
