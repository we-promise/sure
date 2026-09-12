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
