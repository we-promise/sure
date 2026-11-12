require "application_system_test_case"

# The spending chart's axis labels sit in a column on the right that fits the
# widest label with 4px to spare at the card's edge, never narrower than 48px
# (and, past that, at most a third of the chart).
class SpendingChartAxisTest < ApplicationSystemTestCase
  include EntriesTestHelper

  CHART = "#main [data-controller~='spending-chart']".freeze

  setup do
    @user = users(:family_admin)
  end

  test "axis labels of a currency shown by its code fit inside the chart" do
    family = @user.family
    family.update!(currency: "SGD")
    account = family.accounts.create!(name: "SGD Checking", balance: 0, currency: "SGD", accountable: Depository.new)
    travel_to Date.current.beginning_of_month + 14.days
    create_transaction(account: account, currency: "SGD", amount: 12_000, date: Date.current.beginning_of_month - 1.month + 3.days)
    create_transaction(account: account, currency: "SGD", amount: 9_000, date: Date.current.beginning_of_month + 2.days)

    labels = visit_dashboard_and_measure_axis
    # Only meaningful when the labels need more than the minimum column (48px
    # less the 8px padding and 4px gap): a browser locale that writes SGD
    # with a short symbol ("$10K") makes labels that fit it anyway.
    skip "the browser's locale writes these labels too short to need a wider column: #{labels["texts"].inspect}" if labels["widest"] <= 37
    assert_operator labels["column"], :>, 48, "the axis column did not grow for labels that need it: #{labels.inspect}"
    # The column holds the widest label, its 8px padding and the 4px gap,
    # however the browser's locale writes the currency.
    assert_operator labels["column"], :>=, labels["widest"] + 12 - 1, "the axis column is narrower than its widest label needs: #{labels.inspect}"
    assert_operator labels["overflow"], :<=, -3.5, "an axis label runs into or past the chart's edge: #{labels.inspect}"
  end

  test "short axis labels keep their distance from the chart's edge" do
    labels = visit_dashboard_and_measure_axis
    assert_operator labels["texts"].size, :>=, 2, "expected axis labels: #{labels.inspect}"
    assert_operator labels["overflow"], :<=, -3.5, "an axis label runs into or past the chart's edge: #{labels.inspect}"
    assert_operator labels["column"], :>=, 48, "the axis column narrowed: #{labels.inspect}"
  end

  test "a narrow chart keeps the 48px axis column" do
    visit_dashboard_and_measure_axis
    column = page.evaluate_async_script(<<~JS)
      const done = arguments[0];
      const element = document.querySelector(#{CHART.to_json});
      element.style.width = "120px";
      const check = (tries) => {
        const svg = element.querySelector("svg");
        const line = svg?.querySelector("line[stroke-dasharray]");
        if (svg && Number(svg.getAttribute("width")) === 120 && !svg.hasAttribute("preserveAspectRatio") && line) {
          done(Math.round(svg.getBoundingClientRect().right - line.getBoundingClientRect().right));
        } else if (tries > 40) done(null);
        else setTimeout(() => check(tries + 1), 50);
      };
      check(0);
    JS
    assert column, "the chart was not drawn at 120px"
    assert_operator column, :>=, 48, "the axis column of a 120px chart is narrower than 48px"
  end

  private
    def visit_dashboard_and_measure_axis
      sign_in @user
      page.driver.browser.manage.window.resize_to(1100, 900)
      visit root_path
      assert_selector "#{CHART} svg circle"
      page.evaluate_script(<<~JS)
        (() => {
          const svg = document.querySelector("#{CHART} svg circle").ownerSVGElement;
          const box = svg.getBoundingClientRect();
          // The y axis labels (axisRight places them at x = its padding).
          const ticks = Array.from(svg.querySelectorAll("g.tick text")).filter((t) => t.getAttribute("x") > 0);
          const dashed = svg.querySelector("line[stroke-dasharray]").getBoundingClientRect();
          return {
            texts: ticks.map((t) => t.textContent),
            widest: Math.max(...ticks.map((t) => t.getBoundingClientRect().width)),
            overflow: Math.max(...ticks.map((t) => t.getBoundingClientRect().right - box.right)),
            column: Math.round(box.right - dashed.right),
          };
        })()
      JS
    end
end
