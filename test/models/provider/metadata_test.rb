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

  test "registers pluggy with BR region, Bank+Investment kinds, alpha maturity" do
    meta = Provider::Metadata.for("pluggy")
    assert_equal "BR", meta[:region]
    assert_includes meta[:kinds], "Bank"
    assert_includes meta[:kinds], "Investment"
    assert_equal :alpha, meta[:maturity]
    assert_equal "Py", meta[:logo_text]
    assert_not_equal "bg-gray-500", meta[:logo_bg]
  end

  test "unknown provider falls back to gray default" do
    meta = Provider::Metadata.for("definitely_not_a_real_provider_xyz")
    assert_equal "bg-gray-500", meta[:logo_bg]
  end
end
