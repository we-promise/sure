require "test_helper"
require "ostruct"

# Authorization ceremonies on SnaptradeItem: the device flow that new
# connections use, and the deprecated authorization-code + PKCE exchange that
# connections made under #2747 still rely on.
class SnaptradeItemOauthTest < ActiveSupport::TestCase
  setup do
    @item = snaptrade_items(:configured_item)
    @legacy_item = snaptrade_items(:legacy_oauth_item)
  end

  test "apply_oauth_tokens! persists rotated tokens and keeps old refresh token when omitted" do
    @legacy_item.apply_oauth_tokens!(
      "access_token" => "new-at", "refresh_token" => "new-rt",
      "token_type" => "Bearer", "scope" => "read", "expires_in" => 900
    )
    assert_equal "new-at", @legacy_item.oauth_access_token
    assert_equal "new-rt", @legacy_item.oauth_refresh_token
    assert_in_delta 900, @legacy_item.oauth_token_expires_at - Time.current, 10

    @legacy_item.apply_oauth_tokens!("access_token" => "newer-at", "expires_in" => 900)
    assert_equal "newer-at", @legacy_item.oauth_access_token
    assert_equal "new-rt", @legacy_item.oauth_refresh_token, "refresh token must survive rotation that omits it"
  end

  # --- Device flow ---

  test "start_oauth_device_flow works before api credentials are entered" do
    item = snaptrade_items(:unauthorized_item)
    Provider::Snaptrade.any_instance.expects(:start_device_authorization)
      .with(scope: "read")
      .returns({ "device_code" => "dc", "user_code" => "ABCD" })

    assert_equal "ABCD", item.start_oauth_device_flow["user_code"]
  end

  test "complete_oauth_device_flow! stores tokens and marks the item good" do
    @item.update!(status: :requires_update)
    Provider::Snaptrade.any_instance.expects(:poll_device_token)
      .with(device_code: "dc")
      .returns({ "access_token" => "at", "refresh_token" => "rt", "expires_in" => 900 })

    @item.complete_oauth_device_flow!(device_code: "dc")

    assert_equal "at", @item.oauth_access_token
    assert @item.good?
  end

  # --- DEPRECATED authorization-code + PKCE (#2747) ---

  test "complete_oauth_exchange! stores tokens and marks item good" do
    @legacy_item.update!(status: :requires_update)
    Provider::SnaptradeOauth.expects(:exchange_code)
      .with(code: "c0de", redirect_uri: "https://sure.test/cb", code_verifier: "v")
      .returns({ "access_token" => "at", "refresh_token" => "rt", "expires_in" => 900 })

    @legacy_item.complete_oauth_exchange!(code: "c0de", redirect_uri: "https://sure.test/cb", code_verifier: "v")

    assert_equal "at", @legacy_item.oauth_access_token
    assert @legacy_item.good?
  end

  test "destroying a deprecated PKCE connection revokes its tokens best-effort" do
    Provider::SnaptradeOauth.expects(:revoke_token).with(token: @legacy_item.oauth_refresh_token).returns(true)
    @legacy_item.destroy!
  end

  test "destroy proceeds even when revocation raises" do
    Provider::SnaptradeOauth.expects(:revoke_token).raises(Provider::Snaptrade::ApiError.new("boom"))
    assert_difference "SnaptradeItem.count", -1 do
      @legacy_item.destroy!
    end
  end

  test "destroying a device-flow connection deletes its SnapTrade user instead" do
    Provider::SnaptradeOauth.expects(:revoke_token).never
    Provider::Snaptrade.any_instance.expects(:delete_user).with(user_id: @item.snaptrade_user_id).returns(true)

    @item.destroy!
  end
end
