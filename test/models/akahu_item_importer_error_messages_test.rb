require "test_helper"
require_relative "../support/akahu_fixture_fence_helper"

class AkahuItemImporterErrorMessagesTest < ActiveSupport::TestCase
  include AkahuFixtureFenceHelper
  setup do
    @item = AkahuItem.create!(
      family: families(:dylan_family),
      name: "Test Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    @akahu_account = @item.akahu_accounts.create!(
      name: "Test Akahu Account",
      account_id: "akahu-account-1",
      currency: "NZD"
    )
    @account = @item.family.accounts.create!(name: "Linked account", currency: "NZD", balance: 0, accountable: Depository.new)
    AccountProvider.create!(account: @account, provider: @akahu_account)
  end

  test "pending transaction fetch hides raw exception messages from result errors" do
    raw_message = "raw pending payload with sensitive-value"
    provider = mock
    provider.stubs(:get_accounts).returns([])
    provider.stubs(:get_account_transactions).returns([])
    provider.stubs(:get_pending_transactions).raises(StandardError.new(raw_message))

    result = AkahuItem::Importer.new(@item, akahu_provider: provider).import

    assert_equal false, result[:success]
    assert_equal I18n.t("akahu_item.errors.pending_transactions_failed"), result[:error]
    refute_includes result.inspect, raw_message
  end

  test "posted transaction fetch hides raw Akahu error messages from result errors" do
    raw_message = "raw posted payload with sensitive-value"
    provider = mock
    provider.stubs(:get_accounts).returns([])
    provider.stubs(:get_pending_transactions).returns([])
    provider
      .stubs(:get_account_transactions)
      .raises(Provider::Akahu::AkahuError.new(raw_message, :fetch_failed))

    result = AkahuItem::Importer.new(@item, akahu_provider: provider).import

    assert_equal false, result[:success]
    assert_equal 1, result[:transactions_failed]
    assert_empty result[:pending_inventories]
    refute_includes result.inspect, raw_message
  end
end
