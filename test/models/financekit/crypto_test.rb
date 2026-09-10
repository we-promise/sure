require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::CryptoTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  setup { financekit_setup }

  test "Apple-generated cross-language vectors work with production JOSE libraries" do
    vectors = JSON.parse(file_fixture("financekit/apple_vectors.json").read)
    Financekit::Crypto.stubs(:encryption_key).returns(OpenSSL::PKey.read(vectors.fetch("server_private_pem")))
    item = OpenStruct.new(id: vectors.fetch("connection_id"), generation: 1, device_public_key: vectors.fetch("device_public_jwk"))
    claims = Financekit::Crypto.verify(vectors.fetch("upload_jws"), item)
    assert_equal vectors.fetch("payload"), Financekit::Crypto.decrypt(claims.fetch("ciphertext"))
  end

  test "device envelope decrypts and receipt binds the accepted immutable batch" do
    envelope = financekit_envelope
    batch = FinancekitBatch.accept!(@item, envelope)
    decoded, header = JWT.decode(Financekit::Crypto.receipt(batch), @receipt_key, true, algorithms: [ "ES256" ],
      verify_aud: true, aud: @item.id)
    assert_equal batch.digest, decoded["digest"]
    assert_equal batch.batch_id, decoded["batch_id"]
    assert_equal "accepted", decoded["status"]
    assert_equal "sure-financekit-receipt+jwt", header["typ"]
    assert_not_includes envelope, "Synthetic shop"
  end

  test "wrong signing key audience and algorithm cannot authenticate" do
    claims = JWT.decode(financekit_envelope, nil, false).first
    wrong_key = OpenSSL::PKey::EC.generate("prime256v1")
    wrong = JWT.encode(claims, wrong_key, "ES256", { typ: "sure-financekit+jwt" })
    assert_equal 401, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, wrong) }.status
    wrong = JWT.encode(claims.merge("aud" => "attacker"), @device_key, "ES256", { typ: "sure-financekit+jwt" })
    assert_equal 401, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, wrong) }.status
    wrong = JWT.encode(claims, nil, "none", { typ: "sure-financekit+jwt" })
    assert_equal 401, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, wrong) }.status
  end

  test "private device keys and untrusted key URLs are rejected" do
    assert_raises(Financekit::Error) { Financekit::Crypto.public_device_key(@device_jwk.merge("d" => "secret")) }
    claims = JWT.decode(financekit_envelope, nil, false).first
    wrong = JWT.encode(claims, @device_key, "ES256", { typ: "sure-financekit+jwt", jku: "https://example.invalid/keys" })
    assert_equal 400, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, wrong) }.status
  end

  test "ciphertext change fails without disclosing parser errors" do
    claims = JWT.decode(financekit_envelope, nil, false).first
    claims["ciphertext"] = claims["ciphertext"].reverse
    invalid = JWT.encode(claims, @device_key, "ES256", { typ: "sure-financekit+jwt" })
    error = assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, invalid) }
    assert_equal "invalid_digest", error.code
    assert_not_includes error.message, "Synthetic"
  end
end
