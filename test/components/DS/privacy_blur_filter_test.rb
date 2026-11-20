require "test_helper"

class DS::PrivacyBlurFilterTest < ViewComponent::TestCase
  # privacy-mode.css references the filter as url("#privacy-mode-blur").
  test "defines the filter privacy-mode.css references, hidden from assistive tech" do
    render_inline(DS::PrivacyBlurFilter.new)

    assert_selector "svg[aria-hidden='true'] filter#privacy-mode-blur", visible: :all
  end

  # display:none would invalidate the filter reference, so it is sized away.
  test "is sized to nothing rather than hidden" do
    render_inline(DS::PrivacyBlurFilter.new)

    svg = page.find("svg", visible: :all)
    assert_equal %w[absolute w-0 h-0 overflow-hidden], svg[:class].split
  end
end
