# Offline wire-format check. Uses only Ruby's standard OpenSSL and Minitest;
# production uses jwt/json-jwt instead of these test-only JOSE decoding helpers.
require "json"
require "openssl"
require "base64"
require "minitest/autorun"
require "bigdecimal"
module Financekit; end
require_relative "../../../app/models/financekit/mapping"

class FinancekitAppleVectorsTest < Minitest::Test
  def setup
    @vectors = JSON.parse(File.read(File.expand_path("../../fixtures/files/financekit/apple_vectors.json", __dir__)))
  end

  def unbase64(value)
    Base64.urlsafe_decode64(value)
  end

  def public_key(jwk)
    point = "\x04".b + unbase64(jwk.fetch("x")) + unbase64(jwk.fetch("y"))
    algorithm = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::ObjectId("id-ecPublicKey"), OpenSSL::ASN1::ObjectId("prime256v1")
    ])
    OpenSSL::PKey.read(OpenSSL::ASN1::Sequence([ algorithm, OpenSSL::ASN1::BitString(point) ]).to_der)
  end

  def verify_jws(jws, jwk)
    header, payload, encoded_signature = jws.split(".")
    signature = unbase64(encoded_signature)
    assert_equal 64, signature.bytesize
    asn1 = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(signature[0, 32], 2)),
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(signature[32, 32], 2))
    ]).to_der
    assert public_key(jwk).verify("SHA256", asn1, "#{header}.#{payload}")
    JSON.parse(unbase64(payload))
  end

  def test_apple_es256_upload_is_verified_by_ruby_openssl
    claims = verify_jws(@vectors.fetch("upload_jws"), @vectors.fetch("device_public_jwk"))
    assert_equal @vectors.fetch("claims"), claims
    assert_equal "sure-test-server", claims.fetch("aud")
    assert_equal OpenSSL::Digest::SHA256.hexdigest(claims.fetch("ciphertext")), claims.fetch("digest")
  end

  def test_apple_jwe_is_decrypted_by_ruby_openssl
    skip "System Ruby/OpenSSL binding cannot set GCM AAD with LibreSSL; run with the project's Ruby 3.4.9" if OpenSSL::OPENSSL_VERSION.start_with?("LibreSSL")
    protected, wrapped_key, nonce, ciphertext, tag = @vectors.fetch("claims").fetch("ciphertext").split(".")
    assert_equal({ "alg" => "RSA-OAEP", "enc" => "A256GCM" }, JSON.parse(unbase64(protected)))
    rsa = OpenSSL::PKey.read(@vectors.fetch("server_private_pem"))
    cek = rsa.private_decrypt(unbase64(wrapped_key), OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.decrypt
    cipher.key = cek
    cipher.iv = unbase64(nonce)
    cipher.auth_tag = unbase64(tag)
    cipher.auth_data = protected
    plaintext = cipher.update(unbase64(ciphertext)) + cipher.final
    assert_equal @vectors.fetch("payload"), JSON.parse(plaintext)
  end

  def test_apple_receipt_signature_and_batch_binding
    claims = verify_jws(@vectors.fetch("receipt_jws"), @vectors.fetch("receipt_public_jwk"))
    assert_equal @vectors.fetch("connection_id"), claims.fetch("aud")
    assert_equal @vectors.fetch("claims").fetch("digest"), claims.fetch("digest")
    assert_equal @vectors.fetch("claims").fetch("batch_id"), claims.fetch("batch_id")
  end

  def test_production_money_mapping_preserves_decimal_signs
    %w[0 1 1.234 999999999999999.9999].each do |amount|
      credit = { "amount" => amount, "credit_debit" => "credit" }
      debit = credit.merge("credit_debit" => "debit")
      assert_equal -BigDecimal(amount), Financekit::Mapping.transaction_amount(credit)
      assert_equal BigDecimal(amount), Financekit::Mapping.transaction_amount(debit)
      assert_equal BigDecimal(amount), Financekit::Mapping.balance(credit, "Depository")
      assert_equal -BigDecimal(amount), Financekit::Mapping.balance(credit, "CreditCard")
    end
  end
end
