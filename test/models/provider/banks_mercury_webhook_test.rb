require "test_helper"

class ProviderBanksMercuryWebhookTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Banks::Mercury.new(api_key: "x", webhook_signing_secret: "secret")
  end

  test "verifies hex signature within time window" do
    body = { event: "ping" }.to_json
    ts = Time.now.to_i.to_s
    data = "#{ts}.#{body}"
    expected = OpenSSL::HMAC.hexdigest('SHA256', "secret", data)
    headers = { 'X-Mercury-Signature' => expected, 'X-Mercury-Timestamp' => ts }
    assert @provider.verify_webhook_signature!(body, headers)
  end

  test "rejects old timestamp" do
    body = { event: "ping" }.to_json
    ts = (Time.now.to_i - 600).to_s
    data = "#{ts}.#{body}"
    expected = OpenSSL::HMAC.hexdigest('SHA256', "secret", data)
    headers = { 'X-Mercury-Signature' => expected, 'X-Mercury-Timestamp' => ts }
    refute @provider.verify_webhook_signature!(body, headers)
  end

  test "accepts base64 signature format" do
    body = { event: "ping" }.to_json
    ts = Time.now.to_i.to_s
    data = "#{ts}.#{body}"
    hmac_bin = OpenSSL::HMAC.digest('SHA256', "secret", data)
    expected_b64 = Base64.strict_encode64(hmac_bin)
    headers = { 'X-Mercury-Signature' => expected_b64, 'X-Mercury-Timestamp' => ts }
    assert @provider.verify_webhook_signature!(body, headers)
  end
end

