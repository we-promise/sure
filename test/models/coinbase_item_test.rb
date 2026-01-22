require "test_helper"

class CoinbaseItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinbase_item = CoinbaseItem.create!(
      family: @family,
      name: "Test Coinbase Connection",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "belongs to family" do
    assert_equal @family, @coinbase_item.family
  end

  test "has many coinbase_accounts" do
    account = @coinbase_item.coinbase_accounts.create!(
      name: "Bitcoin Wallet",
      account_id: "test_btc_123",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_includes @coinbase_item.coinbase_accounts, account
  end

  test "has good status by default" do
    assert_equal "good", @coinbase_item.status
  end

  test "validates presence of name" do
    item = CoinbaseItem.new(family: @family, api_key: "key", api_secret: "secret")
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "validates presence of api_key" do
    item = CoinbaseItem.new(family: @family, name: "Test", api_secret: "secret")
    assert_not item.valid?
    assert_includes item.errors[:api_key], "can't be blank"
  end

  test "validates presence of api_secret" do
    item = CoinbaseItem.new(family: @family, name: "Test", api_key: "key")
    assert_not item.valid?
    assert_includes item.errors[:api_secret], "can't be blank"
  end

  test "can be marked for deletion" do
    refute @coinbase_item.scheduled_for_deletion?

    @coinbase_item.destroy_later

    assert @coinbase_item.scheduled_for_deletion?
  end

  test "is syncable" do
    assert_respond_to @coinbase_item, :sync_later
    assert_respond_to @coinbase_item, :syncing?
  end

  test "scopes work correctly" do
    # Use explicit timestamp to ensure deterministic ordering
    item_for_deletion = CoinbaseItem.create!(
      family: @family,
      name: "Delete Me",
      api_key: "test_key",
      api_secret: "test_secret",
      scheduled_for_deletion: true,
      created_at: 1.day.ago
    )

    active_items = @family.coinbase_items.active
    ordered_items = @family.coinbase_items.ordered

    assert_includes active_items, @coinbase_item
    refute_includes active_items, item_for_deletion

    # ordered scope sorts by created_at desc, so newer (@coinbase_item) comes first
    assert_equal [ @coinbase_item, item_for_deletion ], ordered_items.to_a
  end

  test "credentials_configured? returns true when both keys present" do
    assert @coinbase_item.credentials_configured?
  end

  test "credentials_configured? returns false when keys missing" do
    @coinbase_item.api_key = nil
    refute @coinbase_item.credentials_configured?

    @coinbase_item.api_key = "key"
    @coinbase_item.api_secret = nil
    refute @coinbase_item.credentials_configured?
  end

  test "set_coinbase_institution_defaults! sets metadata" do
    @coinbase_item.set_coinbase_institution_defaults!

    assert_equal "Coinbase", @coinbase_item.institution_name
    assert_equal "coinbase.com", @coinbase_item.institution_domain
    assert_equal "https://www.coinbase.com", @coinbase_item.institution_url
    assert_equal "#0052FF", @coinbase_item.institution_color
  end

  test "linked_accounts_count returns count of accounts with providers" do
    coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 1.0
    )

    assert_equal 0, @coinbase_item.linked_accounts_count

    account = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: coinbase_account)

    assert_equal 1, @coinbase_item.linked_accounts_count
  end

  test "unlinked_accounts_count returns count of accounts without providers" do
    @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 1.0
    )

    assert_equal 1, @coinbase_item.unlinked_accounts_count
  end

  test "sync_status_summary with no accounts" do
    assert_equal I18n.t("coinbase_items.coinbase_item.sync_status.no_accounts"), @coinbase_item.sync_status_summary
  end

  test "sync_status_summary with one linked account" do
    coinbase_account = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 1.0
    )

    account = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: coinbase_account)

    assert_equal I18n.t("coinbase_items.coinbase_item.sync_status.all_synced", count: 1), @coinbase_item.sync_status_summary
  end

  test "sync_status_summary with multiple linked accounts" do
    # Create first account
    coinbase_account1 = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 1.0
    )
    account1 = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account1, provider: coinbase_account1)

    # Create second account
    coinbase_account2 = @coinbase_item.coinbase_accounts.create!(
      name: "ETH Wallet",
      account_id: "eth_456",
      currency: "ETH",
      current_balance: 10.0
    )
    account2 = Account.create!(
      family: @family,
      name: "Coinbase ETH",
      balance: 25000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account2, provider: coinbase_account2)

    assert_equal I18n.t("coinbase_items.coinbase_item.sync_status.all_synced", count: 2), @coinbase_item.sync_status_summary
  end

  test "sync_status_summary with partial setup" do
    # Create linked account
    coinbase_account1 = @coinbase_item.coinbase_accounts.create!(
      name: "BTC Wallet",
      account_id: "btc_123",
      currency: "BTC",
      current_balance: 1.0
    )
    account = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: coinbase_account1)

    # Create unlinked account
    @coinbase_item.coinbase_accounts.create!(
      name: "ETH Wallet",
      account_id: "eth_456",
      currency: "ETH",
      current_balance: 10.0
    )

    assert_equal I18n.t("coinbase_items.coinbase_item.sync_status.partial_sync", linked_count: 1, unlinked_count: 1), @coinbase_item.sync_status_summary
  end
end
