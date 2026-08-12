# frozen_string_literal: true

require "test_helper"
require "base64"
require "json"
require "openssl"

class Provider::CoinbaseTest < ActiveSupport::TestCase
  TEST_API_KEY = "organizations/test-org/apiKeys/test-key-id".freeze

  # JWT base64url parts omit padding — add the correct amount before decoding.
  def jwt_decode_part(str)
    pad = (4 - str.length % 4) % 4
    Base64.urlsafe_decode64(str + ("=" * pad))
  end

  setup do
    # Generate a fresh P-256 (prime256v1) key per run so no private key material
    # is ever committed to the repo — avoids hardcoded-secret scanner findings.
    ec = OpenSSL::PKey::EC.generate("prime256v1")
    @test_key_multiline = ec.to_pem
    # Simulate the common CDP "JSON paste" format where newlines are escaped as \n.
    @test_key_single_line = @test_key_multiline.gsub("\n", '\n')

    @provider = Provider::Coinbase.new(api_key: TEST_API_KEY, api_secret: @test_key_multiline)
    @provider_escaped = Provider::Coinbase.new(api_key: TEST_API_KEY, api_secret: @test_key_single_line)
  end

  # --- parse_ec_private_key ---

  test "parse_ec_private_key accepts real-newline PEM" do
    key = @provider.send(:parse_ec_private_key, @test_key_multiline)
    assert_instance_of OpenSSL::PKey::EC, key
  end

  test "parse_ec_private_key accepts escaped-newline PEM (JSON paste format)" do
    key = @provider.send(:parse_ec_private_key, @test_key_single_line)
    assert_instance_of OpenSSL::PKey::EC, key
  end

  # --- generate_jwt structure ---

  test "generate_jwt produces a three-part JWT" do
    jwt = @provider.send(:generate_jwt, "GET", "/v2/user")
    parts = jwt.split(".")
    assert_equal 3, parts.length, "JWT must have header.payload.signature"
  end

  test "generate_jwt header has alg ES256" do
    jwt = @provider.send(:generate_jwt, "GET", "/v2/user")
    header = JSON.parse(jwt_decode_part(jwt.split(".").first))
    assert_equal "ES256", header["alg"]
  end

  test "generate_jwt header has kid matching api_key" do
    jwt = @provider.send(:generate_jwt, "GET", "/v2/user")
    header = JSON.parse(jwt_decode_part(jwt.split(".").first))
    assert_equal TEST_API_KEY, header["kid"]
  end

  test "generate_jwt payload includes required CDP claims" do
    jwt = @provider.send(:generate_jwt, "GET", "/v2/user")
    payload = JSON.parse(jwt_decode_part(jwt.split(".")[1]))

    assert_equal TEST_API_KEY, payload["sub"]
    assert_equal "cdp", payload["iss"]
    assert_equal "GET api.coinbase.com/v2/user", payload["uri"]
    assert payload["nbf"].is_a?(Integer)
    assert payload["exp"].is_a?(Integer)
    assert_equal 120, payload["exp"] - payload["nbf"]
  end

  test "generate_jwt signature is 64 bytes (raw r||s for ES256)" do
    jwt = @provider.send(:generate_jwt, "GET", "/v2/user")
    sig_bytes = Base64.urlsafe_decode64(jwt.split(".").last + "==")
    assert_equal 64, sig_bytes.bytesize, "ES256 JWT signature must be exactly 64 bytes (r||s)"
  end

  test "generate_jwt works with escaped-newline PEM key" do
    jwt = @provider_escaped.send(:generate_jwt, "GET", "/v2/user")
    header = JSON.parse(Base64.urlsafe_decode64(jwt.split(".").first + "=="))
    assert_equal "ES256", header["alg"]
  end

  test "generate_jwt signature is verifiable with the corresponding public key" do
    jwt = @provider.send(:generate_jwt, "GET", "/v2/user")
    encoded_header, encoded_payload, encoded_sig = jwt.split(".")

    public_key = OpenSSL::PKey::EC.new(@test_key_multiline)
    message = "#{encoded_header}.#{encoded_payload}"

    # Re-encode raw r||s signature back to DER for OpenSSL verification
    sig_bytes = Base64.urlsafe_decode64(encoded_sig + "==")
    r = OpenSSL::BN.new(sig_bytes[0, 32], 2)
    s = OpenSSL::BN.new(sig_bytes[32, 32], 2)
    der_sig = OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::Integer(r), OpenSSL::ASN1::Integer(s) ]).to_der

    assert public_key.verify(OpenSSL::Digest::SHA256.new, der_sig, message),
      "JWT signature must verify against the EC public key"
  end
end
