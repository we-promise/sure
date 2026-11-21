require "application_system_test_case"

class TimeSeriesChartTest < ApplicationSystemTestCase
  test "chart dates follow the selected locale on desktop and mobile" do
    user = users(:family_admin)
    user.update!(locale: "ru")
    sign_in user

    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit root_path
      assert_selector "#netWorthChart .tick text", count: 2

      ticks = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("#netWorthChart .tick")).map((tick) => ({
          label: tick.textContent,
          expected: new Intl.DateTimeFormat("ru", { day: "numeric", month: "short", year: "numeric" }).format(tick.__data__),
          box: tick.getBoundingClientRect().toJSON(),
          viewport: document.documentElement.clientWidth,
        }))
      JS

      ticks.each do |tick|
        assert_equal tick["expected"], tick["label"]
        assert_operator tick["box"]["left"], :>=, 0
        assert_operator tick["box"]["right"], :<=, tick["viewport"]
      end
    end
  end
end
