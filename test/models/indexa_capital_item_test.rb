# frozen_string_literal: true

require "test_helper"

class IndexaCapitalItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = indexa_capital_items(:configured_with_token)
  end

  test "belongs to family" do
    assert_equal @family, @item.family
  end

  test "has many indexa_capital_accounts" do
    assert_includes @item.indexa_capital_accounts, indexa_capital_accounts(:mutual_fund)
  end

  test "has good status by default" do
    assert_equal "good", @item.status
  end

  test "validates presence of name" do
    item = IndexaCapitalItem.new(family: @family, api_token: "test")
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "valid with api_token only" do
    item = IndexaCapitalItem.new(family: @family, name: "Test", api_token: "test_token")
    assert item.valid?
  end

  test "valid with username/document/password credentials" do
    item = IndexaCapitalItem.new(
      family: @family, name: "Test",
      username: "user@example.com", document: "12345678A", password: "secret"
    )
    assert item.valid?
  end

  test "invalid without any credentials on create" do
    item = IndexaCapitalItem.new(family: @family, name: "Test")
    assert_not item.valid?
    assert item.errors[:base].any?
  end

  test "credentials_configured? returns true with api_token" do
    assert @item.credentials_configured?
  end

  test "credentials_configured? returns true with username/document/password" do
    item = indexa_capital_items(:configured_with_credentials)
    assert item.credentials_configured?
  end

  test "credentials_configured? returns false when nothing set" do
    item = IndexaCapitalItem.new(family: @family, name: "Test")
    refute item.credentials_configured?
  end

  test "indexa_capital_provider returns nil when not configured" do
    item = IndexaCapitalItem.new(family: @family, name: "Test")
    assert_nil item.indexa_capital_provider
  end

  test "indexa_capital_provider returns provider with token auth" do
    provider = @item.indexa_capital_provider
    assert_instance_of Provider::IndexaCapital, provider
  end

  test "indexa_capital_provider returns provider with credentials auth" do
    item = indexa_capital_items(:configured_with_credentials)
    provider = item.indexa_capital_provider
    assert_instance_of Provider::IndexaCapital, provider
  end

  test "can be marked for deletion" do
    refute @item.scheduled_for_deletion?
    @item.destroy_later
    assert @item.scheduled_for_deletion?
  end

  test "is syncable" do
    assert_respond_to @item, :sync_later
    assert_respond_to @item, :syncing?
  end

  test "scopes work correctly" do
    item_for_deletion = IndexaCapitalItem.create!(
      family: @family, name: "Delete Me", api_token: "test",
      scheduled_for_deletion: true, created_at: 1.day.ago
    )

    active_items = @family.indexa_capital_items.active
    assert_includes active_items, @item
    refute_includes active_items, item_for_deletion
  end

  test "linked_accounts_count returns count of accounts with providers" do
    assert_equal 0, @item.linked_accounts_count

    account = Account.create!(
      family: @family, name: "Linked Fund", balance: 1000, currency: "EUR",
      accountable: Investment.new
    )
    AccountProvider.create!(account: account, provider: indexa_capital_accounts(:mutual_fund))

    assert_equal 1, @item.linked_accounts_count
  end

  test "unlinked_accounts_count returns count of accounts without providers" do
    assert_equal 2, @item.unlinked_accounts_count
  end

  test "sync_status_summary with no accounts" do
    item = IndexaCapitalItem.create!(family: @family, name: "Empty", api_token: "test")
    assert_equal I18n.t("indexa_capital_items.sync_status.no_accounts"), item.sync_status_summary
  end

  test "sync_status_summary with all linked" do
    # Link both accounts
    [ indexa_capital_accounts(:mutual_fund), indexa_capital_accounts(:pension_plan) ].each do |ica|
      account = Account.create!(
        family: @family, name: ica.name, balance: 1000, currency: "EUR",
        accountable: Investment.new
      )
      AccountProvider.create!(account: account, provider: ica)
    end

    assert_equal I18n.t("indexa_capital_items.sync_status.synced", count: 2), @item.sync_status_summary
  end

  test "sync_status_summary with partial setup" do
    account = Account.create!(
      family: @family, name: "Fund", balance: 1000, currency: "EUR",
      accountable: Investment.new
    )
    AccountProvider.create!(account: account, provider: indexa_capital_accounts(:mutual_fund))

    assert_equal I18n.t("indexa_capital_items.sync_status.synced_with_setup", linked: 1, unlinked: 1), @item.sync_status_summary
  end
end
