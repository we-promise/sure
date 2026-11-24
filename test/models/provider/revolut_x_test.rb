# frozen_string_literal: true

require "test_helper"

class Provider::RevolutXTest < ActiveSupport::TestCase
  BASE = "https://revx.revolut.com/api"
  # RFC 8032 section 7.1, TEST 1.
  RFC8032_SEED = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
  TIMESTAMP = Time.at(1_700_000_000)

  setup do
    @key = OpenSSL::PKey.new_raw_private_key("ED25519", [ RFC8032_SEED ].pack("H*"))
    @api_key = "a1" * 32
    @provider = Provider::RevolutX.new(api_key: @api_key, private_key: @key)
  end

  test "the RFC 8032 seed yields the pinned public key" do
    assert_includes @key.public_to_pem, "MCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
  end

  test "signs a balances request with the pinned signature" do
    request = stub_request(:get, "#{BASE}/1.0/balances").with(headers: {
      "X-Revx-API-Key" => @api_key,
      "X-Revx-Timestamp" => "1700000000000",
      "X-Revx-Signature" => "9YsJiloOtqfqhHv2ZFDPOMcpJe8EThAc+E4gHYQlyMmDWx0CQRu7C4QOM22q6Nw66/XdmePlwC4iLxZ2TEEfDQ=="
    }).to_return(status: 200, body: "[]")

    travel_to(TIMESTAMP) { @provider.get_balances }

    assert_requested request
  end

  test "signs a transactions request, query included, with the pinned signature" do
    request = stub_request(:get, "#{BASE}/1.0/transactions?start_date=1697408000000&end_date=1700000000000&limit=1900").with(headers: {
      "X-Revx-Timestamp" => "1700000000000",
      "X-Revx-Signature" => "jtMpDlU/xR8GV9lDCmG+L/9s5EnHDhVokwBc4gtMOF3owc2Oc9RWTz9goLaUv13brYpIuy3daiREBPCqYN94BA=="
    }).to_return(status: 200, body: '{"data":[]}')

    travel_to(TIMESTAMP) do
      @provider.get_transactions(start_date: Time.at(1_697_408_000), end_date: TIMESTAMP)
    end

    assert_requested request
  end

  test "a balances request carries a signature that verifies against the public key" do
    key = OpenSSL::PKey.generate_key("ED25519")
    headers = nil
    stub_request(:get, "#{BASE}/1.0/balances").to_return do |request|
      headers = request.headers
      { status: 200, body: '[{"currency":"BTC","total":"1"}]' }
    end

    result = Provider::RevolutX.new(api_key: @api_key, private_key: key).get_balances

    assert_equal [ { "currency" => "BTC", "total" => "1" } ], result
    assert_equal @api_key, headers["X-Revx-Api-Key"]
    message = "#{headers["X-Revx-Timestamp"]}GET/api/1.0/balances"
    public_key = OpenSSL::PKey.read(key.public_to_pem)
    assert public_key.verify(nil, Base64.strict_decode64(headers["X-Revx-Signature"]), message)
  end

  test "public market data is fetched without credentials" do
    stub_request(:get, "#{BASE}/1.0/public/tickers").to_return(status: 200, body: '{"data":[]}')

    @provider.get_tickers

    assert_requested(:get, "#{BASE}/1.0/public/tickers") { |req| req.headers.keys.none? { |name| name.start_with?("X-Revx") } }
  end

  test "every client method issues GET requests only" do
    stub_request(:any, /revx\.revolut\.com/).to_return(status: 200, body: "{}")
    arguments = { get_transactions: { start_date: 1.day.ago, end_date: Time.current } }

    methods = Provider::RevolutX.public_instance_methods(false)
    assert_equal %i[get_balances get_currencies get_sub_accounts get_tickers get_transactions], methods.sort

    methods.each { |method| @provider.public_send(method, **arguments.fetch(method, {})) }

    assert_requested :get, /revx\.revolut\.com/, times: methods.size
    %i[post put patch delete].each { |verb| assert_not_requested verb, /revx\.revolut\.com/ }

    source = Rails.root.join("app/models/provider/revolut_x.rb").read
    assert_no_match(/\b(post|put|patch|delete)\b/i, source)
    assert_no_match(%r{/orders|/otc}, source)
  end

  test "waits Retry-After milliseconds on a 429 and retries" do
    stub_request(:get, "#{BASE}/1.0/balances")
      .to_return({ status: 429, headers: { "Retry-After" => "1500" } }, { status: 200, body: '[{"currency":"USD"}]' })
    @provider.expects(:sleep).with(1.5).once

    assert_equal [ { "currency" => "USD" } ], @provider.get_balances
  end

  test "gives up after three retries on repeated 429s" do
    stub_request(:get, "#{BASE}/1.0/balances").to_return(status: 429)
    @provider.expects(:sleep).with(1.0).times(3)

    assert_raises(Provider::RevolutX::RateLimitError) { @provider.get_balances }
    assert_requested :get, "#{BASE}/1.0/balances", times: 4
  end

  test "caps Retry-After at 60 seconds" do
    stub_request(:get, "#{BASE}/1.0/balances")
      .to_return({ status: 429, headers: { "Retry-After" => "600000" } }, { status: 200, body: "[]" })
    @provider.expects(:sleep).with(60.0).once

    @provider.get_balances
  end

  test "401 and 403 raise AuthenticationError, other failures ApiError" do
    { 401 => Provider::RevolutX::AuthenticationError,
      403 => Provider::RevolutX::AuthenticationError,
      500 => Provider::RevolutX::ApiError }.each do |status, error|
      stub_request(:get, "#{BASE}/1.0/balances").to_return(status: status, body: '{"message":"no"}')

      assert_raises(error) { @provider.get_balances }
    end
  end
end
