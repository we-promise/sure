require "test_helper"

class DS::ProgressRingTest < ViewComponent::TestCase
  test "renders a track circle and a progress arc" do
    render_inline(DS::ProgressRing.new(percent: 50, tone: :success))
    assert_selector "svg circle", count: 2
  end

  test "renders the center percent by default and clamps it" do
    render_inline(DS::ProgressRing.new(percent: 140))
    assert_text "100%"

    render_inline(DS::ProgressRing.new(percent: -10))
    assert_text "0%"
  end

  test "show_percent: false omits the center label" do
    render_inline(DS::ProgressRing.new(percent: 40, show_percent: false))
    assert_no_text "40%"
  end

  test "exposes a progressbar role and value only when labelled" do
    render_inline(DS::ProgressRing.new(percent: 30, label: "Goal progress"))
    assert_selector "[role='progressbar'][aria-valuenow='30'][aria-label='Goal progress']"

    render_inline(DS::ProgressRing.new(percent: 30))
    assert_no_selector "[role='progressbar']"
  end

  test "tone selects the arc stroke color token" do
    assert_equal "var(--color-success)", DS::ProgressRing.new(percent: 1, tone: :success).stroke_color
    assert_equal "var(--color-warning)", DS::ProgressRing.new(percent: 1, tone: :warning).stroke_color
    assert_equal "var(--color-destructive)", DS::ProgressRing.new(percent: 1, tone: :destructive).stroke_color
    # Unknown tone falls back to neutral.
    assert_equal "var(--color-gray-400)", DS::ProgressRing.new(percent: 1, tone: :bogus).stroke_color
  end

  test "dash offset runs from full circumference at 0% to zero at 100%" do
    ring = DS::ProgressRing.new(percent: 0)
    assert_in_delta ring.circumference, ring.dash_offset, 0.001

    full = DS::ProgressRing.new(percent: 100)
    assert_in_delta 0.0, full.dash_offset, 0.001
  end
end
