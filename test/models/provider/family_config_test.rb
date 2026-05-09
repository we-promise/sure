require "test_helper"

class Provider::FamilyConfigTest < ActiveSupport::TestCase
  test "belongs to family" do
    config = provider_family_configs(:truelayer_family_one)
    assert_equal families(:dylan_family), config.family
  end

  test "requires family and provider_key" do
    config = Provider::FamilyConfig.new
    assert_not config.valid?
    assert config.errors[:family].any?
    assert config.errors[:provider_key].any?
  end

  test "credentials are accessible as a hash" do
    config = provider_family_configs(:truelayer_family_one)
    assert_equal "test_client_id", config.credentials["client_id"]
    assert_equal "test_secret", config.credentials["client_secret"]
  end

  test "unique per family and provider_key" do
    config = Provider::FamilyConfig.new(
      family: families(:dylan_family),
      provider_key: "truelayer",
      credentials: {}
    )
    assert_not config.valid?
    assert config.errors[:provider_key].any?
  end

  test "client_id helper returns credentials client_id" do
    config = provider_family_configs(:truelayer_family_one)
    assert_equal "test_client_id", config.client_id
  end

  test "client_secret helper returns credentials client_secret" do
    config = provider_family_configs(:truelayer_family_one)
    assert_equal "test_secret", config.client_secret
  end

  test "rejects credentials with unsupported keys" do
    config = Provider::FamilyConfig.new(
      family: families(:empty),
      provider_key: "truelayer",
      credentials: { "client_id" => "x", "client_secret" => "y", "rogue_key" => "z" }
    )
    assert_not config.valid?
    assert_match(/unsupported keys.*rogue_key/, config.errors[:credentials].first)
  end

  test "accepts credentials with only allowed keys" do
    config = Provider::FamilyConfig.new(
      family: families(:empty),
      provider_key: "truelayer",
      credentials: { "client_id" => "x", "client_secret" => "y" }
    )
    assert config.valid?
  end
end
