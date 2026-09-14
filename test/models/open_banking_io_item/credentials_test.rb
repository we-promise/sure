require "test_helper"

# The credential bundle is where the SSRF guard bites: api_base_url is used verbatim by
# the HTTP client. These cases previously only ran through the controller, one HTTP
# request each.
class OpenBankingIoItem::CredentialsTest < ActiveSupport::TestCase
  def bundle(overrides = {})
    {
      "apiBaseUrl" => "https://open-banking.io",
      "apiKey" => "paste-api-key",
      "encryptionKey" => { "privateKey" => "paste-private-key" }
    }.deep_merge(overrides).to_json
  end

  def parse(json)
    OpenBankingIoItem::Credentials.parse(json)
  end

  test "extracts the three stored fields" do
    result = parse(bundle)

    assert result.valid?
    assert_equal "https://open-banking.io", result.attributes[:api_base_url]
    assert_equal "paste-api-key", result.attributes[:api_key]
    assert_equal "paste-private-key", result.attributes[:private_key]
  end

  test "accepts the privateKeyPkcs8B64 alias" do
    json = { "apiBaseUrl" => "https://open-banking.io", "apiKey" => "k",
             "encryptionKey" => { "privateKeyPkcs8B64" => "b64-key" } }.to_json

    assert_equal "b64-key", parse(json).attributes[:private_key]
  end

  # === SSRF ===

  test "accepts the apex host and its subdomains over https" do
    [ "https://open-banking.io", "https://api.open-banking.io", "https://staging.open-banking.io" ].each do |url|
      assert parse(bundle("apiBaseUrl" => url)).valid?, url
    end
  end

  test "rejects hosts that are not open-banking.io" do
    [
      "http://169.254.169.254/",           # cloud metadata
      "https://169.254.169.254/",
      "http://open-banking.io",            # plain http
      "https://open-banking.io.evil.com",  # look-alike suffix
      "https://openbanking.io",
      "https://evil.com/open-banking.io",
      "https://open-banking.io@evil.com"   # userinfo trick: the host is evil.com
    ].each do |url|
      result = parse(bundle("apiBaseUrl" => url))
      assert_not result.valid?, "#{url} must be rejected"
      assert_equal "credentials_invalid_url", result.error_key
    end
  end

  # === SHAPE ===

  test "rejects a blank paste" do
    assert_equal "credentials_required", parse("").error_key
    assert_equal "credentials_required", parse(nil).error_key
  end

  test "rejects malformed json" do
    assert_equal "credentials_invalid", parse("{not json").error_key
  end

  # Valid JSON of the wrong shape must be a validation error, not a 500.
  test "rejects json that is not an object" do
    [ "null", "[1,2,3]", '"a string"', "42" ].each do |json|
      assert_equal "credentials_invalid", parse(json).error_key, json
    end
  end

  test "rejects a non-object encryptionKey" do
    [ nil, "a string", [ 1, 2 ] ].each do |value|
      json = { "apiBaseUrl" => "https://open-banking.io", "apiKey" => "k", "encryptionKey" => value }.to_json
      assert_equal "credentials_invalid", parse(json).error_key, value.inspect
    end
  end

  test "rejects a bundle missing any of the three required fields" do
    assert_equal "credentials_invalid", parse(bundle("apiKey" => nil)).error_key
    assert_equal "credentials_invalid", parse(bundle("apiBaseUrl" => nil)).error_key
    assert_equal "credentials_invalid", parse(bundle("encryptionKey" => { "privateKey" => nil })).error_key
  end
end
