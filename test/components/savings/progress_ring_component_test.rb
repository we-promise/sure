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
  test "renders default percent label as a single overlay span" do
    rendered = render_inline Savings::ProgressRingComponent.new(percent: 30)
    assert_selector "span", text: "30%"
  end

  test "renders custom label_lines as stacked overlay spans" do
    rendered = render_inline Savings::ProgressRingComponent.new(
      percent: 21,
      label_lines: [ "$1,250", "of $6,000", "21%" ]
    )
    assert_selector "span", text: "$1,250"
    assert_selector "span", text: "of $6,000"
    assert_selector "span", text: "21%"
  end

  test "uses solo `color` override when supplied" do
    rendered = render_inline Savings::ProgressRingComponent.new(percent: 60, color: "#e99537")
    # foreground arc has the inline style with the supplied colour
    assert_match(/stroke: #e99537/, rendered.to_html)
  end

  test "primary_size_class scales with ring size" do
    assert_equal "text-xs",   Savings::ProgressRingComponent.new(percent: 50, size: 72).primary_size_class
    assert_equal "text-sm",   Savings::ProgressRingComponent.new(percent: 50, size: 96).primary_size_class
    assert_equal "text-base", Savings::ProgressRingComponent.new(percent: 50, size: 140).primary_size_class
    assert_equal "text-lg",   Savings::ProgressRingComponent.new(percent: 50, size: 200).primary_size_class
  end
end
