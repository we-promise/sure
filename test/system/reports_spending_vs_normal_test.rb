require "application_system_test_case"

class ReportsSpendingVsNormalTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @account = accounts(:depository)
    @category = @user.family.categories.create!(name: "Treemap Coffee")

    # A year of £10 a month, then £40 this month: four times normal.
    travel_to Date.current.beginning_of_month + 14.days
    12.times { |i| create_transaction(account: @account, date: Date.current.beginning_of_month - (i + 1).months + 2.days, amount: 10, category: @category) }
    create_transaction(account: @account, date: Date.current.beginning_of_month + 1.day, amount: 40, category: @category)

    sign_in @user
    visit reports_path(period_type: :monthly)
  end

  test "the treemap shows spending against normal and opens a category's transactions" do
    within "section[data-section-key='spending_vs_normal']" do
      assert_selector "[data-controller='spending-treemap'] svg g.leaf rect", minimum: 1
      assert_selector "[data-testid='spending-changes'] li", text: "Treemap Coffee"

      box = find("g.leaf[aria-label^='Treemap Coffee']")
      box.hover
    end

    assert_selector "[role='tooltip']", text: "more than normal"

    find("g.leaf[aria-label^='Treemap Coffee']").click

    assert_current_path(/\/transactions\?/)
    assert_includes URI.decode_www_form_component(current_url), "Treemap Coffee"
  end

  test "Enter on a box opens its transactions without grabbing the section" do
    section = find("section[data-section-key='spending_vs_normal']")
    section.find("g.leaf[aria-label^='Treemap Coffee']").send_keys(:enter)

    assert_current_path(/\/transactions\?/)

    # Turbo restores the page as it was when Enter navigated away
    page.go_back
    assert_selector "section[data-section-key='spending_vs_normal'][aria-grabbed='false']"
  end

  # Group headers draw the name and the amount as separate texts so Privacy
  # Mode can blur the amount alone. However narrow the group, the amount stays
  # inside it, or the header leaves it out.
  test "a group header keeps its amount inside the group at any width" do
    parent = @user.family.categories.create!(name: "WOMBAT MEMBERSHIPS")
    [ [ "Repairs", 12_345 ], [ "Cleaning", 23_456 ] ].each do |name, amount|
      sub = @user.family.categories.create!(name: name, parent: parent)
      create_transaction(account: @account, date: Date.current.beginning_of_month + 1.day, amount: amount, category: sub)
    end
    visit reports_path(period_type: :monthly)

    chart = "section[data-section-key='spending_vs_normal'] [data-spending-treemap-target='chart']"
    assert_selector "#{chart} g.group text", text: "WOMB"
    assert_selector "#{chart} g.group text.privacy-sensitive"

    [ 400, 300, 240, 200, 160, 120, 90, 60 ].each do |width|
      page.execute_script("document.querySelector(arguments[0]).style.width = arguments[1]", chart, "#{width}px")
      assert_selector "#{chart} svg[width='#{width}']"

      overflowing = page.evaluate_script(<<~JS, chart)
        [...document.querySelector(arguments[0]).querySelectorAll("g.group")].flatMap((g) =>
          [...g.querySelectorAll("text.privacy-sensitive")]
            .filter((t) => { const b = t.getBBox(); return b.x + b.width > g.__data__.x1 - 4 + 0.5 })
            .map((t) => t.textContent))
      JS
      assert_empty overflowing, "group header amount overflows at #{width}px"
    end
  end
end
