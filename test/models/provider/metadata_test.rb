require "test_helper"

class Provider::MetadataTest < ActiveSupport::TestCase
  test "provider metadata can define multiple kinds" do
    assert_equal %w[Bank Investment], Provider::Metadata.for(:akahu)[:kinds]
  end

  test "akahu supports multiple kinds" do
    providers_with_multiple_kinds = Provider::Metadata::REGISTRY.select { |_provider_key, metadata| metadata[:kinds].size > 1 }

    assert_includes providers_with_multiple_kinds.keys, :akahu
  end

  test "registered provider metadata only uses kinds" do
    Provider::Metadata::REGISTRY.each_value do |metadata|
      assert metadata.key?(:kinds)
      refute metadata.key?(:kind)
    end
  end

  test "registered provider metadata keeps fallback colors out of raw tailwind classes" do
    Provider::Metadata::REGISTRY.each_value do |metadata|
      refute metadata.key?(:logo_bg)
      assert_match(/\A#[0-9a-f]{6}\z/i, metadata[:logo_color]) if metadata[:logo_color].present?
    end
  end

  test "each account provider's display name is both its panel title and its metadata name" do
    Settings::ProvidersController::FAMILY_PANELS.each do |panel|
      assert_equal panel[:title], Provider::Metadata.for(panel[:key])[:name], "#{panel[:key]} names itself twice"
    end
    assert_equal "Apple Wallet", Provider::Metadata.for(:financekit)[:name]
    assert_equal "Plaid", Provider::Metadata.for(:plaid)[:name]
  end

  test "every declared account provider has metadata from its declaration" do
    Provider::Factory.connection_declarations.each do |declaration|
      metadata = Provider::Metadata::REGISTRY.fetch(declaration[:key].to_sym)
      assert metadata.slice(:region, :kinds, :maturity, :logo_text).values.all?(&:present?), "#{declaration[:key]} metadata is incomplete"
    end
    assert_equal Provider::Factory.metadata_declarations.map { |metadata| metadata[:key] }.sort,
                 Provider::Factory.connection_declarations.map { |declaration| declaration[:key] }.sort
  end

  test "providers without a connection of their own keep hand-written metadata" do
    assert_equal "Plaid EU", Provider::Metadata.for(:plaid_eu)[:name]
    assert_equal %w[Property], Provider::Metadata.for(:rentcast)[:kinds]
    assert_equal %i[chimnie realie rentcast], Provider::Metadata::REGISTRY.select { |_key, metadata| metadata[:kinds] == %w[Property] }.keys.sort
  end

  test "logo_url builds a Brandfetch URL from the provider domain" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)

    assert_equal "https://cdn.brandfetch.io/wise.com/icon/fallback/404/w/40/h/40?c=test-client-id",
                 Provider::Metadata.logo_url(:wise)
  end

  test "logo_url is nil when Brandfetch is not configured" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    assert_nil Provider::Metadata.logo_url(:wise)
  end

  test "logo_url is nil for providers without a domain" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")

    assert_nil Provider::Metadata.logo_url(:onchain_wallet)
    assert_nil Provider::Metadata.logo_url(:unknown_provider)
  end
end
