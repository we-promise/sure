# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Provider::QuestradeTest < ActiveSupport::TestCase
  # Security: the single-use refresh token must travel in the POST body so it
  # can't leak into URLs / access logs / error-tracking breadcrumbs.
  test "authenticate! sends the refresh token in the POST body, not the URL" do
    token_payload = {
      access_token: "access-123",
      api_server: "https://api01.example.com/",
      refresh_token: "rotated-456",
      expires_in: 1800
    }.to_json

    Provider::Questrade.expects(:post)
      .with(Provider::Questrade::LOGIN_URL, body: { grant_type: "refresh_token", refresh_token: "secret-rt" })
      .returns(OpenStruct.new(code: 200, body: token_payload))
    # Guard against regressing to a GET that carries the token in the query string.
    Provider::Questrade.expects(:get).never

    provider = Provider::Questrade.new(refresh_token: "secret-rt")
    provider.send(:authenticate!)

    assert_equal "rotated-456", provider.refresh_token, "rotated token should be surfaced for persistence"
  end
end
