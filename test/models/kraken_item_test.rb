require "test_helper"

class KrakenItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @kraken_item = KrakenItem.create!(
      family: @family,
      name: "Test Kraken Connection",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "belongs to family" do
    assert_equal @family, @kraken_item.family
  end

  test "has many kraken_accounts" do
    account = @kraken_item.kraken_accounts.create!(
      name: "Bitcoin Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 0.5
    )

    assert_includes @kraken_item.kraken_accounts, account
  end

  test "has good status by default" do
    assert_equal "good", @kraken_item.status
  end

  test "validates presence of name" do
    item = KrakenItem.new(family: @family, api_key: "key", api_secret: "secret")
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "validates presence of api_key" do
    item = KrakenItem.new(family: @family, name: "Test", api_secret: "secret")
    assert_not item.valid?
    assert_includes item.errors[:api_key], "can't be blank"
  end

  test "validates presence of api_secret" do
    item = KrakenItem.new(family: @family, name: "Test", api_key: "key")
    assert_not item.valid?
    assert_includes item.errors[:api_secret], "can't be blank"
  end

  test "can be marked for deletion" do
    refute @kraken_item.scheduled_for_deletion?
    @kraken_item.destroy_later
    assert @kraken_item.scheduled_for_deletion?
  end

  test "is syncable" do
    assert_respond_to @kraken_item, :sync_later
    assert_respond_to @kraken_item, :syncing?
  end

  test "scopes work correctly" do
    item_for_deletion = KrakenItem.create!(
      family: @family,
      name: "Delete Me",
      api_key: "test_key",
      api_secret: "test_secret",
      scheduled_for_deletion: true,
      created_at: 1.day.ago
    )

    active_items = @family.kraken_items.active
    ordered_items = @family.kraken_items.ordered

    assert_includes active_items, @kraken_item
    refute_includes active_items, item_for_deletion
    assert_equal [ @kraken_item, item_for_deletion ], ordered_items.to_a
  end

  test "credentials_configured? returns true when both keys present" do
    assert @kraken_item.credentials_configured?
  end

  test "credentials_configured? returns false when keys missing" do
    @kraken_item.api_key = nil
    refute @kraken_item.credentials_configured?

    @kraken_item.api_key = "key"
    @kraken_item.api_secret = nil
    refute @kraken_item.credentials_configured?
  end

  test "set_kraken_institution_defaults! sets metadata" do
    @kraken_item.set_kraken_institution_defaults!

    assert_equal "Kraken", @kraken_item.institution_name
    assert_equal "kraken.com", @kraken_item.institution_domain
    assert_equal "https://www.kraken.com", @kraken_item.institution_url
    assert_equal "#1A1A1A", @kraken_item.institution_color
  end

  test "linked_accounts_count returns count of accounts with providers" do
    kraken_account = @kraken_item.kraken_accounts.create!(
      name: "BTC Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 1.0
    )

    assert_equal 0, @kraken_item.linked_accounts_count

    account = Account.create!(
      family: @family,
      name: "Kraken BTC",
      balance: 50000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: kraken_account)

    assert_equal 1, @kraken_item.linked_accounts_count
  end

  test "unlinked_accounts_count returns count of accounts without providers" do
    @kraken_item.kraken_accounts.create!(
      name: "BTC Balance",
      account_id: "BTC",
      currency: "BTC",
      current_balance: 1.0
    )

    assert_equal 1, @kraken_item.unlinked_accounts_count
  end

  test "sync_status_summary with no accounts" do
    assert_equal I18n.t("kraken_items.kraken_item.sync_status.no_accounts"), @kraken_item.sync_status_summary
  end
end
