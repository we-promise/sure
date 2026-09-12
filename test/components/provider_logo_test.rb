require "test_helper"

class ProviderLogoTest < ViewComponent::TestCase
  setup do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)
  end

  test "lays the brand icon over the fallback when the provider has a domain" do
    stub_metadata(domain: "example.com", logo_icon: "wallet", logo_text: "EX", logo_bg: "bg-gray-500")

    render_inline(ProviderLogo.new(provider_key: :example))

    assert_selector "img[src='https://cdn.brandfetch.io/example.com/icon/fallback/404/w/40/h/40?c=test-client-id']"
    assert_selector "img[onerror='#{ProviderLogo::REMOVE_ON_ERROR}']"
    assert_selector "span.bg-gray-500 + img"
  end

  test "renders only the fallback when the provider has no domain" do
    stub_metadata(logo_icon: "wallet", logo_text: "EX", logo_bg: "bg-gray-500")

    render_inline(ProviderLogo.new(provider_key: :example))

    assert_no_selector "img"
    assert_selector "span.bg-gray-500 svg"
  end

  test "renders only the fallback when Brandfetch is not configured" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    stub_metadata(domain: "example.com", logo_icon: "wallet", logo_text: "EX", logo_bg: "bg-gray-500")

    render_inline(ProviderLogo.new(provider_key: :example))

    assert_no_selector "img"
    assert_selector "span.bg-gray-500 svg"
  end

  test "prefers the icon over the initials in the fallback" do
    stub_metadata(logo_icon: "wallet", logo_text: "EX", logo_bg: "bg-gray-500")

    render_inline(ProviderLogo.new(provider_key: :example))

    assert_selector "span.bg-gray-500 svg"
    assert_no_text "EX"
  end

  test "falls back to the initials when there is no icon" do
    stub_metadata(logo_text: "EX", logo_bg: "bg-gray-500")

    render_inline(ProviderLogo.new(provider_key: :example))

    assert_no_selector "svg"
    assert_selector "span.bg-gray-500", text: "EX"
  end

  test "applies the size and shape classes to the container" do
    stub_metadata(domain: "example.com", logo_text: "EX", logo_bg: "bg-gray-500")

    render_inline(ProviderLogo.new(provider_key: :example, class_name: "w-9 h-9 rounded-lg"))

    assert_selector "span.w-9.h-9.rounded-lg > span.bg-gray-500"
    assert_selector "span.w-9.h-9.rounded-lg > img"
  end

  private
    def stub_metadata(**metadata)
      Provider::Metadata.stubs(:for).with(:example).returns(metadata)
    end
end
