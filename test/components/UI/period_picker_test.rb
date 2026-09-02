require "test_helper"

class UI::PeriodPickerTest < ViewComponent::TestCase
  test "renders one menuitemradio link per period, all carrying the period param and target frame" do
    render_inline(UI::PeriodPicker.new(selected: "last_30_days", url: "/", frame: "dashboard_sections"))

    links = page.all("a[role='menuitemradio']")
    assert_equal Period.all.size, links.size

    links.each do |link|
      assert_match(/period=/, link[:href])
      assert_equal "dashboard_sections", link["data-turbo-frame"]
    end
  end

  test "marks the selected period with aria-checked and a check glyph" do
    render_inline(UI::PeriodPicker.new(selected: "last_90_days", url: "/", frame: "dashboard_sections"))

    selected = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, selected.size
    assert_match(/period=last_90_days/, selected.first[:href])
    # Check icon (svg) renders inside the selected item only.
    assert_selector "a[aria-checked='true'] svg"
  end

  test "trigger button shows the selected period's short label" do
    render_inline(UI::PeriodPicker.new(selected: "last_30_days", url: "/"))

    assert_text Period.from_key("last_30_days").label_short
  end

  test "trigger accessible name announces the selected period" do
    render_inline(UI::PeriodPicker.new(selected: "last_90_days", url: "/"))

    label = Period.from_key("last_90_days").label_short
    assert_selector "button[aria-label='Time period: #{label}']"
  end

  test "extra_params are merged into every option href" do
    render_inline(UI::PeriodPicker.new(
      selected: "last_30_days",
      url: "/accounts/abc",
      extra_params: { chart_view: "balance" }
    ))

    href = page.first("a[role='menuitemradio']")[:href]
    assert_match(%r{\A/accounts/abc\?}, href)
    assert_match(/chart_view=balance/, href)
    assert_match(/period=/, href)
  end

  test "accepts a Period object as selected" do
    render_inline(UI::PeriodPicker.new(selected: Period.last_7_days, url: "/"))

    assert_text Period.from_key("last_7_days").label_short
    assert_equal 1, page.all("a[aria-checked='true']").size
  end

  test "trigger shows a custom range's dates rather than falling back to a preset label" do
    custom_period = Period.custom(start_date: 15.days.ago.to_date, end_date: Date.current)

    render_inline(UI::PeriodPicker.new(selected: custom_period, url: "/"))

    assert_selector "button[aria-label='Time period: #{custom_period.label_range}']"
  end

  test "a custom range adds a trailing checked row so the list still has one selection" do
    custom_period = Period.custom(start_date: 15.days.ago.to_date, end_date: Date.current)

    render_inline(UI::PeriodPicker.new(selected: custom_period, url: "/"))

    links = page.all("a[role='menuitemradio']")
    assert_equal Period.all.size + 1, links.size
    assert_equal custom_period.label_short, links.last.text.strip

    checked = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, checked.size
    # Round-trips the active range, so selecting it re-applies rather than clears.
    assert_match(/start_date=#{custom_period.start_date}/, checked.first[:href])
    assert_match(/end_date=#{custom_period.end_date}/, checked.first[:href])
  end

  test "a preset selection renders no custom row" do
    render_inline(UI::PeriodPicker.new(selected: Period.last_30_days, url: "/"))

    assert_equal Period.all.size, page.all("a[role='menuitemradio']").size
  end

  test "framed options advance the URL so a preset pick clears a stale custom range" do
    render_inline(UI::PeriodPicker.new(selected: Period.last_30_days, url: "/", frame: "dashboard_sections"))

    links = page.all("a[role='menuitemradio'][aria-checked='false']")
    assert links.any?
    links.each { |link| assert_equal "advance", link["data-turbo-action"] }
  end

  test "options advance the URL without an explicit frame too" do
    # The account page renders its picker inside the account's own container
    # frame, so those links are frame navigations as well and need the same
    # address-bar update.
    render_inline(UI::PeriodPicker.new(selected: Period.last_30_days, url: "/"))

    links = page.all("a[role='menuitemradio'][aria-checked='false']")
    assert links.any?
    links.each { |link| assert_equal "advance", link["data-turbo-action"] }
  end

  test "re-picking the checked preset replaces instead of stacking a history entry" do
    render_inline(UI::PeriodPicker.new(selected: Period.last_30_days, url: "/", frame: "dashboard_sections"))

    checked = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, checked.size
    # Selecting the active row is a no-op; advancing would make Back a no-op too.
    assert_equal "replace", checked.first["data-turbo-action"]
  end

  test "the custom row replaces so re-selecting the active range costs no history" do
    custom_period = Period.custom(start_date: 15.days.ago.to_date, end_date: Date.current)

    render_inline(UI::PeriodPicker.new(selected: custom_period, url: "/"))

    links = page.all("a[role='menuitemradio']")
    assert_equal "replace", links.last["data-turbo-action"]
    # Leaving the custom range for a preset is a real change, so it still advances
    # and stays reachable with Back — the drag-select that set it advanced too.
    assert_equal "advance", links.first["data-turbo-action"]
  end
end
