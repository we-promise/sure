require "test_helper"

class UI::PeriodPickerTest < ViewComponent::TestCase
  test "renders one menuitem link per period, all carrying the period param and target frame" do
    render_inline(UI::PeriodPicker.new(selected: "last_30_days", url: "/", frame: "dashboard_sections"))

    links = page.all("a[role='menuitem']")
    assert_equal Period.all.size, links.size

    links.each do |link|
      assert_match(/period=/, link[:href])
      assert_equal "dashboard_sections", link["data-turbo-frame"]
    end
  end

  test "marks the selected period with aria-current and a check glyph" do
    render_inline(UI::PeriodPicker.new(selected: "last_90_days", url: "/", frame: "dashboard_sections"))

    selected = page.all("a[role='menuitem'][aria-current='true']")
    assert_equal 1, selected.size
    assert_match(/period=last_90_days/, selected.first[:href])
    # Check icon (svg) renders inside the selected item only.
    assert_selector "a[aria-current='true'] svg"
  end

  test "trigger button shows the selected period's short label" do
    render_inline(UI::PeriodPicker.new(selected: "last_30_days", url: "/"))

    assert_text Period.from_key("last_30_days").label_short
  end

  test "extra_params are merged into every option href" do
    render_inline(UI::PeriodPicker.new(
      selected: "last_30_days",
      url: "/accounts/abc",
      extra_params: { chart_view: "balance" }
    ))

    href = page.first("a[role='menuitem']")[:href]
    assert_match(%r{\A/accounts/abc\?}, href)
    assert_match(/chart_view=balance/, href)
    assert_match(/period=/, href)
  end

  test "accepts a Period object as selected" do
    render_inline(UI::PeriodPicker.new(selected: Period.last_7_days, url: "/"))

    assert_text Period.from_key("last_7_days").label_short
    assert_equal 1, page.all("a[aria-current='true']").size
  end
end
