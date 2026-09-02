require "test_helper"

class OpenBankingIoItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  def build_item(api_base_url:)
    OpenBankingIoItem.new(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: api_base_url,
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
  end

  # Polish: model-layer SSRF defense-in-depth. An api_base_url that is not pinned
  # to open-banking.io must be rejected at the model layer, not just the controller.
  test "is invalid when api_base_url is not an open-banking.io host" do
    item = build_item(api_base_url: "https://169.254.169.254/latest/meta-data")

    assert_not item.valid?
    assert_includes item.errors.attribute_names, :api_base_url
  end

  test "is invalid for a look-alike host" do
    assert_not build_item(api_base_url: "https://open-banking.io.evil.com").valid?
  end

  test "is invalid for a plain http url" do
    assert_not build_item(api_base_url: "http://open-banking.io").valid?
  end

  test "is valid for open-banking.io and its subdomains" do
    assert build_item(api_base_url: "https://open-banking.io").valid?
    assert build_item(api_base_url: "https://api.open-banking.io").valid?
    assert build_item(api_base_url: "https://staging.open-banking.io").valid?
  end

  # Fix 5: api_base_url/api_key are non-deterministically encrypted (nothing
  # queries them by value). They must still round-trip through save/reload.
  test "api_base_url and api_key round-trip through non-deterministic encryption" do
    item = build_item(api_base_url: "https://staging.open-banking.io")
    item.api_key = "secret-key"
    item.save!

    reloaded = OpenBankingIoItem.find(item.id)
    assert_equal "https://staging.open-banking.io", reloaded.api_base_url
    assert_equal "secret-key", reloaded.api_key
  end

  # The default self-hosted install auto-derives working ActiveRecord encryption keys from
  # SECRET_KEY_BASE, but Encryptable#encryption_ready? only asks explicitly_configured?
  # (env vars or credentials) -- so encryption is live at runtime while the columns are
  # declared unencrypted, and the PKCS#8 key that decrypts every envelope sits in plaintext.
  test "encryption tracks what is actually in force, not just what was declared" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:runtime_configured?).returns(true)

    assert OpenBankingIoItem.encryption_ready?,
           "auto-derived self-hosted keys must count as ready"
    assert OpenBankingIoAccount.encryption_ready?
  end

  test "encryption is off only when nothing is configured at all" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:runtime_configured?).returns(false)

    assert_not OpenBankingIoItem.encryption_ready?
  end

  test "the credential columns are the ones declared encrypted" do
    skip "encryption not configured in this environment" unless OpenBankingIoItem.encryption_ready?

    %i[api_base_url api_key private_key].each do |attribute|
      assert_includes OpenBankingIoItem.encrypted_attributes.to_a, attribute
    end
  end
end
