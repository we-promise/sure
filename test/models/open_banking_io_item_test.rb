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
end
