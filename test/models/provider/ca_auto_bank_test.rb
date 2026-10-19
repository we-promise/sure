require "test_helper"
require Rails.root.join("test/support/ca_auto_bank_test_helper")

class Provider::CaAutoBankTest < ActiveSupport::TestCase
  include CaAutoBankTestHelper

  test "SmartCode login and polling send credentials only to the fixed bank routes" do
    token = ca_token
    start = stub_request(:post, "#{Provider::CaAutoBank::ORIGIN}#{Provider::CaAutoBank::AUTH_ROOT}/login")
      .with(body: { email: "owner@example.com", password: "synthetic-password", loginRequestingPlatform: "CUSTOMER_PORTAL" }.to_json)
      .to_return(status: 511, body: { errorCode: 5110000, appAuthorizationRequired: true, verificationToken: "private-verification" }.to_json)
    poll = stub_request(:post, "#{Provider::CaAutoBank::ORIGIN}#{Provider::CaAutoBank::AUTH_ROOT}/login/tfa")
      .with(body: { verificationToken: "private-verification" }.to_json)
      .to_return(status: 511, body: { errorCode: 5110003, appAuthorizationRequired: true }.to_json)
      .then.to_return(status: 200, body: { authenticationToken: token }.to_json)

    client = Provider::CaAutoBank.new
    assert_match(/\A[A-Za-z0-9]{26}\z/, client.request_session_id)
    challenge = client.begin_login(email: "owner@example.com", password: "synthetic-password")
    refute challenge.authenticated?
    refute_includes challenge.inspect, "private-verification"
    refute client.poll_login(verification_token: challenge.verification_token).authenticated?
    assert_equal token, client.poll_login(verification_token: challenge.verification_token).authentication_token
    assert_requested start, times: 1
    assert_requested poll, times: 2
  end

  test "an unverified SMS flow fails with a safe unsupported message" do
    stub_request(:post, /\/login\z/).to_return(status: 511,
      body: { errorCode: 5110000, appAuthorizationRequired: false, verificationToken: "private-verification" }.to_json)
    error = assert_raises(Provider::CaAutoBank::Error) { Provider::CaAutoBank.new.begin_login(email: "owner@example.com", password: "synthetic-password") }
    assert_equal "unsupported_login", error.code
    refute_includes error.message, "private-verification"
  end

  test "expired sessions and redirects fail without following or exposing bank responses" do
    stub_request(:get, /\/user\z/).to_return(status: 401, body: '{"message":"private bank response"}')
    client = Provider::CaAutoBank.new(authentication_token: ca_token)
    error = assert_raises(Provider::CaAutoBank::Error) { client.account_identity }
    assert_equal "session_expired", error.code
    refute_includes error.message, "private bank response"

    stub_request(:get, /\/user\z/).to_return(status: 302, headers: { "Location" => "https://untrusted.example/" })
    assert_raises(Provider::CaAutoBank::Error) { client.account_identity }
    assert_not_requested(:get, "https://untrusted.example/")
  end

  test "HTTP 429 preserves Retry-After without exposing the response body" do
    stub_request(:get, /\/user\z/).to_return(status: 429, body: "private limit response",
      headers: { "Retry-After" => "3600" })

    error = assert_raises(Provider::CaAutoBank::Error) do
      Provider::CaAutoBank.new(authentication_token: ca_token).account_identity
    end

    assert_equal "rate_limited", error.code
    assert_equal "3600", error.retry_after
    assert_equal 429, error.diagnostics.fetch(:http_status)
    refute_includes error.message, "private"
    refute_includes error.diagnostics.to_json, "private"
  end

  test "token expiry accepts only the observed JWT format" do
    expiry = 1.hour.from_now.change(usec: 0)
    assert_equal expiry.to_i, Provider::CaAutoBank.token_expires_at(ca_token(expires_at: expiry)).to_i
    [ "not-a-token", "a.b.c", ca_token.sub("synthetic-signature", "") ].each do |token|
      assert_raises(Provider::CaAutoBank::Error) { Provider::CaAutoBank.token_expires_at(token) }
    end
  end

  test "approval failures expose only fixed operation and numeric response diagnostics" do
    stub_request(:post, /\/login\/tfa\z/).to_return(status: 503,
      body: { errorCode: 5030001, message: "private backend response", verificationToken: "private-verification" }.to_json)
    error = assert_raises(Provider::CaAutoBank::Error) do
      Provider::CaAutoBank.new.poll_login(verification_token: "private-verification")
    end
    assert_equal "provider_unavailable", error.code
    assert_equal({ operation: "approval_check", http_status: 503, bank_error_code: 5030001 }, error.diagnostics)
    refute_includes error.inspect, "private"
    refute_includes error.diagnostics.to_json, "private"

    stub_request(:post, /\/login\/tfa\z/).to_return(status: 200, body: "private invalid JSON")
    error = assert_raises(Provider::CaAutoBank::Error) do
      Provider::CaAutoBank.new.poll_login(verification_token: "private-verification")
    end
    assert_equal "invalid_response", error.code
    assert_equal({ operation: "approval_check", http_status: 200 }, error.diagnostics)
  end

  test "snapshot retrieval matches contracts and requests only active deposit read queries" do
    item = Struct.new(:account_identity, :connection_generation).new("synthetic-partner", 1)
    bundle = ca_snapshot(item).reports.sole
    root = "#{Provider::CaAutoBank::ORIGIN}#{Provider::CaAutoBank::DEPOSIT_ROOT}"
    stub_request(:get, /\/user\z/).to_return(status: 200, body: { partnerId: "synthetic-partner" }.to_json)
    stub_request(:get, root).to_return(status: 200, body: { depositAccountReports: [ bundle.fetch("report") ] }.to_json)
    stub_request(:get, "#{root}/contracts").to_return(status: 200, body: { depositAccountContracts: [ bundle.fetch("contract") ] }.to_json)
    stub_request(:post, "#{root}/overview").to_return(status: 200, body: bundle.fetch("overview").to_json)
    stub_request(:post, "#{root}/time-deposits/processed").with { |request| JSON.parse(request.body)["status"] == "ACTIVE" }
      .to_return(status: 200, body: { processedTimeDeposits: bundle.fetch("deposits").map { |row| row.fetch("summary") } }.to_json)
    bundle.fetch("deposits").each do |row|
      stub_request(:post, "#{root}/time-deposits/details").with { |request| JSON.parse(request.body)["operationNumber"] == row.dig("summary", "operationNumber") }
        .to_return(status: 200, body: row.fetch("details").to_json)
    end

    snapshot = Provider::CaAutoBank.new(authentication_token: ca_token).fetch_snapshot(identity: item.account_identity, generation: 1)
    assert_equal 3, CaAutoBankItem::SnapshotNormalizer.new.normalize(snapshot).accounts.size
    assert_not_requested(:post, "#{root}/time-deposits")
    assert_not_requested(:put, /\/transfers/)
  end
end
