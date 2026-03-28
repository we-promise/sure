require "test_helper"

class KrakenAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @kraken_item = KrakenItem.create!(
      family: @family,
      name: "Test Kraken",
      api_key: "test_key",
      api_secret: "test_secret"
    )
    @kraken_account = @kraken_item.kraken_accounts.create!(
      name: "Bitcoin Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 0.5
    )
  end

  test "belongs to kraken_item" do
    assert_equal @kraken_item, @kraken_account.kraken_item
  end

  test "validates presence of name" do
    account = KrakenAccount.new(kraken_item: @kraken_item, currency: "BTC")
    assert_not account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  test "validates presence of currency" do
    account = KrakenAccount.new(kraken_item: @kraken_item, name: "Test")
    assert_not account.valid?
    assert_includes account.errors[:currency], "can't be blank"
  end

  test "upsert_kraken_snapshot! updates account data" do
    snapshot = {
      "id" => "ETH",
      "name" => "Ethereum Balance",
      "balance" => 1.5,
      "status" => "active",
      "currency" => "ETH"
    }

    @kraken_account.upsert_kraken_snapshot!(snapshot)

    assert_equal "ETH", @kraken_account.account_id
    assert_equal "Ethereum Balance", @kraken_account.name
    assert_equal 1.5, @kraken_account.current_balance
    assert_equal "active", @kraken_account.account_status
  end

  test "upsert_kraken_transactions_snapshot! stores transaction data" do
    transactions = {
      "trades" => [
        { "id" => "tx1", "type" => "buy", "vol" => "0.1" }
      ]
    }

    @kraken_account.upsert_kraken_transactions_snapshot!(transactions)
    assert_equal transactions, @kraken_account.raw_transactions_payload
  end

  test "current_account returns linked account when account_provider exists" do
    account = Account.create!(
      family: @family,
      name: "Kraken BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: @kraken_account)

    @kraken_account.reload
    assert_equal account, @kraken_account.current_account
  end

  test "ensure_account_provider! creates provider link" do
    account = Account.create!(
      family: @family,
      name: "Kraken BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    assert_difference "AccountProvider.count", 1 do
      @kraken_account.ensure_account_provider!(account)
    end

    @kraken_account.reload
    assert_equal account, @kraken_account.current_account
  end
end
