require "test_helper"

class PluggyItemTest < ActiveSupport::TestCase
  test "credentials_configured? requires both secrets" do
    item = PluggyItem.new(family: families(:dylan_family), name: "x")
    refute item.credentials_configured?
    item.client_id = "c"
    item.client_secret = "s"
    assert item.credentials_configured?
  end

  test "client_user_id is stable and family-scoped" do
    item = pluggy_items(:one)
    assert_equal "pluggy_#{item.family_id}", item.client_user_id
  end

  test "pluggy_provider delegates get_accounts with credentials" do
    item = pluggy_items(:one)
    Provider::Pluggy.expects(:get_accounts).with(item_id: "item-1", client_id: "test_client", client_secret: "test_secret", type: nil).returns([ { "id" => "a1" } ])
    assert_equal [ { "id" => "a1" } ], item.pluggy_provider.get_accounts
  end

  test "pluggy_provider delegates connect_token with clientUserId" do
    item = pluggy_items(:one)
    Provider::Pluggy.expects(:connect_token).with(
      client_id: "test_client", client_secret: "test_secret",
      client_user_id: item.client_user_id,
      webhook_url: item.webhook_url, redirect_url: item.redirect_url
    ).returns("tok")
    assert_equal "tok", item.pluggy_provider.connect_token(client_user_id: item.client_user_id, webhook_url: item.webhook_url, redirect_url: item.redirect_url)
  end
end
