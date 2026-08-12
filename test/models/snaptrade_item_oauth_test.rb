require "test_helper"
require "ostruct"

class SnaptradeItemOauthTest < ActiveSupport::TestCase
  setup do
    @item = snaptrade_items(:configured_item)
  end

  test "syncable scope includes only active items with an access token" do
    assert_includes SnaptradeItem.syncable, snaptrade_items(:configured_item)
    assert_not_includes SnaptradeItem.syncable, snaptrade_items(:unauthorized_item)
  end

  test "oauth_configured? and fully_configured? reflect token presence" do
    assert @item.oauth_configured?
    assert @item.fully_configured?
    assert_not snaptrade_items(:unauthorized_item).oauth_configured?
  end

  test "apply_oauth_tokens! persists rotated tokens and keeps old refresh token when omitted" do
    @item.apply_oauth_tokens!(
      "access_token" => "new-at", "refresh_token" => "new-rt",
      "token_type" => "Bearer", "scope" => "read", "expires_in" => 900
    )
    assert_equal "new-at", @item.oauth_access_token
    assert_equal "new-rt", @item.oauth_refresh_token
    assert_in_delta 900, @item.oauth_token_expires_at - Time.current, 10

    @item.apply_oauth_tokens!("access_token" => "newer-at", "expires_in" => 900)
    assert_equal "newer-at", @item.oauth_access_token
    assert_equal "new-rt", @item.oauth_refresh_token, "refresh token must survive rotation that omits it"
  end

  test "complete_oauth_exchange! stores tokens and marks item good" do
    @item.update!(status: :requires_update)
    Provider::Snaptrade.expects(:exchange_code)
      .with(code: "c0de", redirect_uri: "https://sure.test/cb", code_verifier: "v")
      .returns({ "access_token" => "at", "refresh_token" => "rt", "expires_in" => 900 })

    @item.complete_oauth_exchange!(code: "c0de", redirect_uri: "https://sure.test/cb", code_verifier: "v")

    assert_equal "at", @item.oauth_access_token
    assert @item.good?
  end

  test "snaptrade_provider returns provider only when token present" do
    assert_instance_of Provider::Snaptrade, @item.snaptrade_provider
    assert_nil snaptrade_items(:unauthorized_item).snaptrade_provider
  end

  test "destroy revokes tokens best-effort" do
    Provider::Snaptrade.expects(:revoke_token).with(token: @item.oauth_refresh_token).returns(true)
    @item.destroy!
  end

  test "destroy proceeds even when revocation raises" do
    Provider::Snaptrade.expects(:revoke_token).raises(Provider::Snaptrade::ApiError.new("boom"))
    assert_difference "SnaptradeItem.count", -1 do
      @item.destroy!
    end
  end
end
