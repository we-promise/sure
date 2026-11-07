require "test_helper"

class SaxoItemTest < ActiveSupport::TestCase
  setup do
    Setting.saxo_app_key = "application-key"
    Setting.saxo_app_secret = "application-secret"
    @item = families(:dylan_family).saxo_items.create!(
      access_token: "old-access", refresh_token: "old-refresh", access_expires_at: 1.minute.from_now,
      refresh_expires_at: 40.minutes.from_now, application_key_digest: Provider::Saxo.application_key_digest,
      redirect_uri: "https://sure.example/saxo_items/callback")
  end

  test "token renewal sends only refresh grant parameters" do
    request = stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token")
      .with(body: { "grant_type" => "refresh_token", "refresh_token" => "old-refresh" },
        headers: { "Authorization" => "Basic #{Base64.strict_encode64('application-key:application-secret')}" })
      .to_return(body: {
        access_token: "new-access", refresh_token: "new-refresh",
        expires_in: 1200, refresh_token_expires_in: 2400
      }.to_json)

    assert_equal "new-access", @item.access_token!
    assert_equal "new-refresh", @item.reload.refresh_token
    assert_requested request, times: 1
  end

  test "a stale second instance reuses the persisted token instead of spending a refresh token twice" do
    stale = SaxoItem.find(@item.id)
    Provider::Saxo.expects(:exchange).once.returns(access_token: "new-access", refresh_token: "new-refresh",
      access_expires_at: 20.minutes.from_now, refresh_expires_at: 40.minutes.from_now)
    assert_equal "new-access", @item.access_token!
    assert_equal "new-access", stale.access_token!
    assert_equal "new-refresh", stale.reload.refresh_token
  end

  test "a rejected token already replaced by another request is not refreshed again" do
    stale = SaxoItem.find(@item.id)
    Provider::Saxo.expects(:exchange).once.returns(access_token: "new-access", refresh_token: "new-refresh",
      access_expires_at: 20.minutes.from_now, refresh_expires_at: 40.minutes.from_now)
    assert_equal "new-access", @item.access_token!(force_refresh: true, rejected_token: "old-access")
    assert_equal "new-access", stale.access_token!(force_refresh: true, rejected_token: "old-access")
  end

  test "rejected authorization marks the item for reconnect without replacing the token" do
    Provider::Saxo.stubs(:exchange).raises(Provider::Saxo::AuthenticationError, "reconnect")
    assert_raises(Provider::Saxo::AuthenticationError) { @item.access_token! }
    assert @item.reload.requires_update?
    assert_equal "old-refresh", @item.refresh_token
  end

  test "tokens are encrypted in persisted attributes" do
    assert_no_match "old-refresh", @item.read_attribute_before_type_cast("refresh_token")
    assert_no_match "old-access", @item.read_attribute_before_type_cast("access_token")
    assert_equal "old-refresh", @item.reload.refresh_token
  end

  test "expired refresh tokens do not attempt an exchange" do
    @item.update!(refresh_expires_at: 1.second.ago)
    Provider::Saxo.expects(:exchange).never
    assert_raises(Provider::Saxo::AuthenticationError) { @item.access_token! }
    assert @item.reload.requires_update?
  end
end
