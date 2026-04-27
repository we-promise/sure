require "test_helper"

class Savings::ProgressRingComponentTest < ViewComponent::TestCase
  test "renders an svg with role and aria-label" do
    render_inline Savings::ProgressRingComponent.new(percent: 42)
    assert_selector "svg[role='img'][aria-label='42% complete']"
  end

  test "clamps percent to [0, 100]" do
    rendered = render_inline Savings::ProgressRingComponent.new(percent: 250)
    assert_match "100%", rendered.text
    rendered = render_inline Savings::ProgressRingComponent.new(percent: -10)
    assert_match "0%", rendered.text
  end
end
