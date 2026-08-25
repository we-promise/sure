require "test_helper"

class AkahuItemImporterErrorMessagesTest < ActiveSupport::TestCase
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
  end

  test "pending transaction fetch hides raw exception messages from result errors" do
    raw_message = "raw pending payload with sensitive-value"
    provider = mock
    provider.stubs(:get_pending_transactions).raises(StandardError.new(raw_message))

    result = AkahuItem::Importer
      .new(@item, akahu_provider: provider)
      .send(:fetch_pending_transactions_by_account)

    assert_equal false, result[:success]
    assert_equal I18n.t("akahu_item.errors.pending_transactions_failed"), result[:error]
    refute_includes result.inspect, raw_message
  end

  test "posted transaction fetch hides raw Akahu error messages from result errors" do
    raw_message = "raw posted payload with sensitive-value"
    provider = mock
    provider
      .stubs(:get_account_transactions)
      .raises(Provider::Akahu::AkahuError.new(raw_message, :fetch_failed))

    result = AkahuItem::Importer
      .new(@item, akahu_provider: provider)
      .send(:fetch_and_store_transactions, @akahu_account, [], pending_refresh_succeeded: true)

    assert_equal false, result[:success]
    assert_equal I18n.t("akahu_item.errors.transactions_failed"), result[:error]
    refute_includes result.inspect, raw_message
  end
end
