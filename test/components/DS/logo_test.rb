require "test_helper"

class DS::LogoTest < ViewComponent::TestCase
  test "missing logo renders local initial without an image request" do
    render_inline DS::Logo.new(src: nil, name: "Wise EUR")
    assert_no_selector "img"
    assert_selector "[data-image-fallback-target='fallback']:not([hidden])", text: "W"
  end

  test "remote logo includes a hidden local fallback and decorative image" do
    render_inline DS::Logo.new(src: "https://cdn.brandfetch.io/wise.com?c=test", name: "Wise EUR")
    assert_selector "img[alt=''][loading='lazy'][data-action*='error->image-fallback#showFallback']"
    assert_selector "[data-image-fallback-target='fallback'][hidden]", text: "W", visible: :all
  end
end
