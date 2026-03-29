# frozen_string_literal: true

require "test_helper"

class BinanceItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(
      family: @family,
      name: "My Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "belongs to family" do
    assert_equal @family, @item.family
  end

  test "has good status by default" do
    assert_equal "good", @item.status
  end

  test "validates presence of name" do
    item = BinanceItem.new(family: @family, api_key: "k", api_secret: "s")
    assert_not item.valid?
    assert_includes item.errors[:name], "can't be blank"
  end

  test "validates presence of api_key" do
    item = BinanceItem.new(family: @family, name: "B", api_secret: "s")
    assert_not item.valid?
    assert_includes item.errors[:api_key], "can't be blank"
  end

  test "validates presence of api_secret" do
    item = BinanceItem.new(family: @family, name: "B", api_key: "k")
    assert_not item.valid?
    assert_includes item.errors[:api_secret], "can't be blank"
  end

  test "active scope excludes scheduled for deletion" do
    @item.update!(scheduled_for_deletion: true)
    refute_includes BinanceItem.active.to_a, @item
  end

  test "credentials_configured? returns true when both keys present" do
    assert @item.credentials_configured?
  end

  test "credentials_configured? returns false when api_key nil" do
    @item.api_key = nil
    refute @item.credentials_configured?
  end

  test "destroy_later marks for deletion" do
    @item.destroy_later
    assert @item.scheduled_for_deletion?
  end

  test "set_binance_institution_defaults! sets metadata" do
    @item.set_binance_institution_defaults!
    assert_equal "Binance", @item.institution_name
    assert_equal "binance.com", @item.institution_domain
    assert_equal "https://www.binance.com", @item.institution_url
    assert_equal "#F0B90B", @item.institution_color
  end

  test "sync_status_summary with no accounts" do
    assert_equal I18n.t("binance_items.binance_item.sync_status.no_accounts"), @item.sync_status_summary
  end

  test "linked_accounts_count returns correct count" do
    ba = @item.binance_accounts.create!(name: "Binance", account_type: "combined", currency: "USD")
    assert_equal 0, @item.linked_accounts_count

    account = Account.create!(
      family: @family, name: "Binance", balance: 0, currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: ba)

    assert_equal 1, @item.linked_accounts_count
  end
end
