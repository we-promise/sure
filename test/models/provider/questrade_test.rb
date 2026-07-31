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
  # Security/correctness: the single-use token exchange must be serialized and
  # must spend the freshest persisted token (see provided.rb#synchronize_exchange).
  test "authenticate! spends the freshest token inside synchronize_exchange" do
    token_payload = {
      access_token: "at", api_server: "https://api01.example.com/",
      refresh_token: "rotated", expires_in: 1800
    }.to_json

    lock_calls = 0
    # The lock yields a token newer than the one the provider was built with.
    sync = ->(&blk) { lock_calls += 1; blk.call("fresh-from-lock") }

    # The exchange must use the locked/fresh token, not the stale initial one.
    Provider::Questrade.expects(:post)
      .with(Provider::Questrade::LOGIN_URL, body: { grant_type: "refresh_token", refresh_token: "fresh-from-lock" })
      .returns(OpenStruct.new(code: 200, body: token_payload))

    provider = Provider::Questrade.new(refresh_token: "stale-initial", synchronize_exchange: sync)
    provider.send(:authenticate!)

    assert_equal 1, lock_calls, "exchange must run inside the synchronize_exchange lock"
    assert_equal "rotated", provider.refresh_token
  end

  test "retries network errors and raises Error after max retries exhausted" do
    provider = Provider::Questrade.new(refresh_token: "test-rt")
    # Authenticate first to set api_server and access_token
    auth_payload = { access_token: "at", api_server: "https://api01.example.com/", refresh_token: "rt2", expires_in: 1800 }.to_json
    Provider::Questrade.stubs(:post).returns(OpenStruct.new(code: 200, body: auth_payload))
    provider.send(:authenticate!)

    provider.stubs(:sleep)
    DebugLogEntry.stubs(:capture)

    attempt_count = 0
    Provider::Questrade.stubs(:get).with { |*| attempt_count += 1; true }.raises(SocketError, "connection failed")

    error = assert_raises(Provider::Questrade::Error) do
      provider.list_accounts
    end

    assert_equal Provider::Questrade::MAX_RETRIES + 1, attempt_count
    assert_match "Network error after #{Provider::Questrade::MAX_RETRIES} retries", error.message
  end

  test "retries on 429 rate limit and raises Error after max retries exhausted" do
    provider = Provider::Questrade.new(refresh_token: "test-rt")
    auth_payload = { access_token: "at", api_server: "https://api01.example.com/", refresh_token: "rt2", expires_in: 1800 }.to_json
    Provider::Questrade.stubs(:post).returns(OpenStruct.new(code: 200, body: auth_payload))
    provider.send(:authenticate!)

    provider.stubs(:sleep)
    DebugLogEntry.stubs(:capture)

    stub_429 = OpenStruct.new(code: 429, body: "{}")
    Provider::Questrade.stubs(:get).returns(stub_429)

    error = assert_raises(Provider::Questrade::Error) do
      provider.list_accounts
    end

    assert_match "Network error after #{Provider::Questrade::MAX_RETRIES} retries", error.message
  end

  test "retries on 5xx server error and raises Error after max retries exhausted" do
    provider = Provider::Questrade.new(refresh_token: "test-rt")
    auth_payload = { access_token: "at", api_server: "https://api01.example.com/", refresh_token: "rt2", expires_in: 1800 }.to_json
    Provider::Questrade.stubs(:post).returns(OpenStruct.new(code: 200, body: auth_payload))
    provider.send(:authenticate!)

    provider.stubs(:sleep)
    DebugLogEntry.stubs(:capture)

    stub_503 = OpenStruct.new(code: 503, body: "{}")
    Provider::Questrade.stubs(:get).returns(stub_503)

    assert_raises(Provider::Questrade::Error) do
      provider.list_accounts
    end
  end
end
