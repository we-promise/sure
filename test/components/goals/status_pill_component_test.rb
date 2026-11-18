require "test_helper"

class Goals::StatusPillComponentTest < ViewComponent::TestCase
  # Without its own variant an unmeasurable goal fell back to the "Open"
  # styling, the infinity glyph of an open-ended goal it is not.
  test "a goal whose pace cannot be measured gets a gray question-mark pill" do
    component = Goals::StatusPillComponent.new(goal: OpenStruct.new(display_status: :pace_unknown))

    assert_equal({ tone: :gray, icon: "circle-help" }, component.variant)

    render_inline(component)
    assert_text I18n.t("goals.status.pace_unknown")
  end
end
