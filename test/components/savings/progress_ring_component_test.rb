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

class Savings::ProgressRingLabelLinesTest < ViewComponent::TestCase
  test "renders default percent label as a single tspan" do
    rendered = render_inline Savings::ProgressRingComponent.new(percent: 30)
    assert_selector "tspan", text: "30%"
  end

  test "renders custom label_lines as stacked tspans" do
    rendered = render_inline Savings::ProgressRingComponent.new(
      percent: 21,
      label_lines: [ "$1,250", "of $6,000", "21%" ]
    )
    assert_selector "tspan", text: "$1,250"
    assert_selector "tspan", text: "of $6,000"
    assert_selector "tspan", text: "21%"
  end

  test "uses solo `color` override when supplied" do
    rendered = render_inline Savings::ProgressRingComponent.new(percent: 60, color: "#e99537")
    # foreground arc has the inline style with the supplied colour
    assert_match(/stroke: #e99537/, rendered.to_html)
  end
end
