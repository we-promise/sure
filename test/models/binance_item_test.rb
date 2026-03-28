require "test_helper"

class BinanceItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @binance_item = BinanceItem.create!(
      family: @family,
      name: "Test Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "belongs to family" do
    assert_equal @family, @binance_item.family
  end

  test "has many binance_accounts" do
    account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD"
    )

    assert_includes @binance_item.binance_accounts, account
  end

  test "defaults to good status" do
    assert_equal "good", @binance_item.status
  end

  test "credentials_configured? returns true when credentials are present" do
    assert @binance_item.credentials_configured?
  end

  test "credentials_configured? returns false when credentials are missing" do
    @binance_item.api_key = nil
    refute @binance_item.credentials_configured?

    @binance_item.api_key = "test_key"
    @binance_item.api_secret = nil
    refute @binance_item.credentials_configured?
  end

  test "destroy_later marks item for deletion" do
    refute @binance_item.scheduled_for_deletion?

    @binance_item.destroy_later

    assert @binance_item.scheduled_for_deletion?
  end

  test "set_binance_institution_defaults! sets metadata" do
    @binance_item.set_binance_institution_defaults!

    assert_equal "Binance", @binance_item.institution_name
    assert_equal "binance.com", @binance_item.institution_domain
    assert_equal "https://www.binance.com", @binance_item.institution_url
    assert_equal "#F0B90B", @binance_item.institution_color
  end

  test "linked_accounts_count counts linked provider accounts" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD"
    )
    account = Account.create!(
      family: @family,
      name: "Linked Crypto",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    assert_equal 0, @binance_item.linked_accounts_count

    AccountProvider.create!(account: account, provider: binance_account)

    assert_equal 1, @binance_item.linked_accounts_count
  end

  test "unlinked_accounts_count counts unlinked provider accounts" do
    @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD"
    )

    assert_equal 1, @binance_item.unlinked_accounts_count
  end

  test "sync_status_summary returns no accounts message" do
    assert_equal I18n.t("binance_items.binance_item.sync_status.no_accounts"), @binance_item.sync_status_summary
  end

  test "sync_status_summary returns all synced message" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "uid_123",
      currency: "USD"
    )
    account = Account.create!(
      family: @family,
      name: "Linked Crypto",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: binance_account)

    assert_equal I18n.t("binance_items.binance_item.sync_status.all_synced", count: 1), @binance_item.sync_status_summary
  end

  test "sync_status_summary returns partial sync message" do
    linked = @binance_item.binance_accounts.create!(
      name: "Linked Spot",
      account_id: "uid_123",
      currency: "USD"
    )
    @binance_item.binance_accounts.create!(
      name: "Unlinked Spot",
      account_id: "uid_456",
      currency: "USD"
    )
    account = Account.create!(
      family: @family,
      name: "Linked Crypto",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: linked)

    assert_equal(
      I18n.t("binance_items.binance_item.sync_status.partial_sync", linked_count: 1, unlinked_count: 1),
      @binance_item.sync_status_summary
    )
  end
end
