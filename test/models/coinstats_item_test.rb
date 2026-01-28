require "test_helper"

class CoinstatsItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
  end

  test "belongs to family" do
    assert_equal @family, @coinstats_item.family
  end

  test "has many coinstats_accounts" do
    account = @coinstats_item.coinstats_accounts.create!(
      name: "Test Wallet",
      currency: "USD",
      current_balance: 1000.00
    )

    assert_includes @coinstats_item.coinstats_accounts, account
  end

  test "has good status by default" do
    assert_equal "good", @coinstats_item.status
  end

  test "can be marked for deletion" do
    refute @coinstats_item.scheduled_for_deletion?

    @coinstats_item.destroy_later

    assert @coinstats_item.scheduled_for_deletion?
  end

  test "is syncable" do
    assert_respond_to @coinstats_item, :sync_later
    assert_respond_to @coinstats_item, :syncing?
  end

  test "requires name to be present" do
    coinstats_item = CoinstatsItem.new(family: @family, api_key: "key")
    coinstats_item.name = nil

    assert_not coinstats_item.valid?
    assert_includes coinstats_item.errors[:name], "can't be blank"
  end

  test "requires api_key to be present" do
    coinstats_item = CoinstatsItem.new(family: @family, name: "Test")
    coinstats_item.api_key = nil

    assert_not coinstats_item.valid?
    assert_includes coinstats_item.errors[:api_key], "can't be blank"
  end

  test "requires api_key to be present on update" do
    @coinstats_item.api_key = ""

    assert_not @coinstats_item.valid?
    assert_includes @coinstats_item.errors[:api_key], "can't be blank"
  end

  test "scopes work correctly" do
    # Create one for deletion
    item_for_deletion = CoinstatsItem.create!(
      family: @family,
      name: "Delete Me",
      api_key: "delete_key",
      scheduled_for_deletion: true
    )

    active_items = CoinstatsItem.active
    ordered_items = CoinstatsItem.ordered

    assert_includes active_items, @coinstats_item
    refute_includes active_items, item_for_deletion

    assert_equal [ @coinstats_item, item_for_deletion ].sort_by(&:created_at).reverse,
                 ordered_items.to_a
  end

  test "needs_update scope returns items requiring update" do
    @coinstats_item.update!(status: :requires_update)

    good_item = CoinstatsItem.create!(
      family: @family,
      name: "Good Item",
      api_key: "good_key"
    )

    needs_update_items = CoinstatsItem.needs_update

    assert_includes needs_update_items, @coinstats_item
    refute_includes needs_update_items, good_item
  end

  test "institution display name returns name when present" do
    assert_equal "Test CoinStats Connection", @coinstats_item.institution_display_name
  end

  test "institution display name falls back to CoinStats" do
    # Bypass validation by using update_column
    @coinstats_item.update_column(:name, "")
    assert_equal "CoinStats", @coinstats_item.institution_display_name
  end

  test "credentials_configured? returns true when api_key present" do
    assert @coinstats_item.credentials_configured?
  end

  test "credentials_configured? returns false when api_key blank" do
    @coinstats_item.api_key = nil
    refute @coinstats_item.credentials_configured?
  end

  test "upserts coinstats snapshot" do
    snapshot_data = {
      total_balance: 5000.0,
      wallets: [ { address: "0x123", blockchain: "ethereum" } ]
    }

    @coinstats_item.upsert_coinstats_snapshot!(snapshot_data)
    @coinstats_item.reload

    # Verify key data is stored correctly (keys may be string or symbol)
    assert_equal 5000.0, @coinstats_item.raw_payload["total_balance"]
    assert_equal 1, @coinstats_item.raw_payload["wallets"].count
    assert_equal "0x123", @coinstats_item.raw_payload["wallets"].first["address"]
  end

  test "has_completed_initial_setup? returns false when no accounts" do
    refute @coinstats_item.has_completed_initial_setup?
  end

  test "has_completed_initial_setup? returns true when accounts exist" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Test Wallet",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    assert @coinstats_item.has_completed_initial_setup?
  end

  test "linked_accounts_count returns count of accounts with provider links" do
    # Initially no linked accounts
    assert_equal 0, @coinstats_item.linked_accounts_count

    # Create a linked account
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Test Wallet",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    assert_equal 1, @coinstats_item.linked_accounts_count
  end

  test "unlinked_accounts_count returns count of accounts without provider links" do
    # Create an unlinked account
    @coinstats_item.coinstats_accounts.create!(
      name: "Unlinked Wallet",
      currency: "USD"
    )

    assert_equal 1, @coinstats_item.unlinked_accounts_count
  end

  test "sync_status_summary shows no accounts message" do
    assert_equal "No crypto wallets found", @coinstats_item.sync_status_summary
  end

  test "sync_status_summary shows all synced message" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Test Wallet",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    assert_equal "1 crypto wallet synced", @coinstats_item.sync_status_summary
  end

  test "sync_status_summary shows mixed status message" do
    # Create a linked account
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Linked Wallet",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    # Create an unlinked account
    @coinstats_item.coinstats_accounts.create!(
      name: "Unlinked Wallet",
      currency: "USD"
    )

    assert_equal "1 crypto wallets synced, 1 need setup", @coinstats_item.sync_status_summary
  end
end
