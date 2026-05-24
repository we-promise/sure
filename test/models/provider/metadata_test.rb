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
end
