require "test_helper"

class Provider::Auth::OAuth2Test < ActiveSupport::TestCase
  setup do
    @connection = provider_connections(:monzo_connection)
    @auth = Provider::Auth::OAuth2.new(@connection)
  end

  test "fresh_access_token returns stored token when not expired" do
    assert_equal "test_token", @auth.fresh_access_token
  end

  test "fresh_access_token refreshes when token is expired" do
    @connection.update!(credentials: @connection.credentials.merge("expires_at" => 1.hour.ago.to_i))
    mock_tokens = OpenStruct.new(
      access_token: "new_token",
      refresh_token: "new_refresh",
      expires_in: 3600
    )
    Provider::Auth::OAuth2.any_instance.expects(:fetch_new_tokens).returns(mock_tokens)
    token = @auth.fresh_access_token # pipelock:ignore
    assert_equal "new_token", token
    assert_equal "new_token", @connection.reload.credentials["access_token"]
  end

  test "fresh_access_token raises ReauthRequiredError on consent expired" do
    @connection.update!(credentials: @connection.credentials.merge("expires_at" => 1.hour.ago.to_i))
    Provider::Auth::OAuth2.any_instance.expects(:fetch_new_tokens).raises(Provider::Auth::ConsentExpiredError)
    assert_raises(Provider::Auth::ReauthRequiredError) { @auth.fresh_access_token }
    assert @connection.reload.requires_update?
  end

  test "fresh_access_token raises ReauthRequiredError on token revoked" do
    @connection.update!(credentials: @connection.credentials.merge("expires_at" => 1.hour.ago.to_i))
    Provider::Auth::OAuth2.any_instance.expects(:fetch_new_tokens).raises(Provider::Auth::TokenRevokedError)
    assert_raises(Provider::Auth::ReauthRequiredError) { @auth.fresh_access_token }
    assert @connection.reload.requires_update?
  end

  test "store_tokens persists all token fields" do
    tokens = OpenStruct.new(access_token: "tok", refresh_token: "ref", expires_in: 300)
    @auth.store_tokens(tokens)
    creds = @connection.reload.credentials
    assert_equal "tok", creds["access_token"]
    assert_equal "ref", creds["refresh_token"]
    assert_in_delta Time.current.to_i + 300, creds["expires_at"].to_i, 5
  end

  test "store_tokens persists consent_expires_at when provided" do
    tokens = OpenStruct.new(access_token: "tok", refresh_token: "ref", expires_in: 3600)
    expiry = 90.days.from_now
    @auth.store_tokens(tokens, consent_expires_at: expiry)
    assert_equal expiry.iso8601, @connection.reload.metadata["consent_expires_at"]
  end

  test "family_credentials raises NotImplementedError when provider_family_config is missing" do
    @connection.update!(provider_family_config: nil)
    error = assert_raises(NotImplementedError) { @auth.send(:family_credentials) }
    assert_match "non-BYOK OAuth providers must override family_credentials", error.message
  end
end
