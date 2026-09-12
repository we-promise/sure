require "application_system_test_case"

# The one thing the Ruby and controller-level tests cannot say.
#
# Loan::PayoffChartTest proves the payload is right, and the controller test
# proves it reaches the data attribute. Neither proves a line is PAINTED --
# which is the failure mode this chart has already been reported for once
# (#101: a projected payoff line that renders with correct geometry and no
# error, because its stroke never resolved to a colour).
#
# So these assertions are deliberately about the rendered SVG and the DOM
# around it: that each series exists as a path with real geometry and a
# stroke that will mark the screen, in both themes; that the data table and
# the keyboard give a screen-reader or keyboard user the same figures (gate
# G6); and that the live region stays quiet under a pointer. A test that
# re-checked payoff dates here would be re-running Loan::PayoffChartTest
# through a browser, slowly.
class LoanPayoffChartTest < ApplicationSystemTestCase
  # Pinned so the schedule, the projection and therefore the number of drawn
  # series are the same run to run. The loan opens 2026-01-01 over 24 months,
  # so this sits mid-term with real history behind it and real term ahead.
  TODAY = Date.new(2027, 1, 15)
  SERIES = %w[actual scheduled projected].freeze

  setup do
    sign_in @user = users(:family_admin)
  end

  test "the chart paints all three lines, in the light theme and the dark" do
    travel_to TODAY do
      account = on_contract_loan_account

      visit account_path(account, period: "all_time")
      assert_selector "[data-controller='loan-payoff-chart'] svg"

      assert_series_painted
      strokes_in_light = SERIES.to_h { |key| [ key, stroke_of(key) ] }

      # The strokes are live CSS variables, so the browser repaints them from
      # the dark palette without a redraw; nothing in the controller watches
      # the theme. Wait on the computed stroke itself.
      page.execute_script("document.documentElement.setAttribute('data-theme', 'dark')")
      wait_until { stroke_of("actual") != strokes_in_light["actual"] }
      assert_series_painted
      assert_not_equal strokes_in_light["actual"], stroke_of("actual"),
        "the recorded line must repaint from the dark theme's token"
    end
  end

  # Gate G6: the table the SVG describes itself with carries the same rows the
  # lines are drawn from, and it is real DOM the page exposes rather than a
  # screen-reader-only summary.
  test "the SVG is described by a data table with one row per plotted date" do
    travel_to TODAY do
      account = on_contract_loan_account
      payload = Loan::PayoffChart.new(account.loan, as_of: TODAY, period: all_time_period).payload

      visit account_path(account, period: "all_time")
      assert_selector "[data-controller='loan-payoff-chart'] svg"

      svg = find("[data-controller='loan-payoff-chart'] svg")
      table_id = svg["aria-details"]
      assert_equal ActionView::RecordIdentifier.dom_id(account, :loan_chart_table), table_id
      assert_nil svg["aria-describedby"],
        "describedby would flatten every table cell into the chart's description"

      find("details summary", text: I18n.t("UI.account.chart.loan.view_as_table")).click
      assert_selector "table##{table_id} tbody tr", count: payload[:rows].length
      assert_selector "p.sr-only", text: payload[:aria_description], visible: :all
      assert_equal payload[:aria_description],
        find("[data-controller='loan-payoff-chart'] svg")["aria-label"]
    end
  end

  # Gate G6: every plotted date is reachable from the keyboard, and only the
  # keyboard talks to the live region -- a pointer sweeping the chart would
  # otherwise announce on every movement (#57).
  test "arrow keys step the tooltip through the plotted dates and only they announce" do
    travel_to TODAY do
      account = on_contract_loan_account

      visit account_path(account, period: "all_time")
      svg = find("[data-controller='loan-payoff-chart'] svg")
      assert_equal "0", svg["tabindex"], "the chart must be focusable"

      svg.send_keys(:arrow_right)
      tooltip = find("[data-controller='loan-payoff-chart'] div[aria-live='polite']", visible: :all)
      first = tooltip.text(:all)
      assert_match I18n.t("UI.account.chart.loan.scheduled"), first
      # jjmata on we-promise/sure#3474: the tooltip is built from
      # utils/chart_tooltip, so it shares the other charts' surface and z-index.
      assert_includes tooltip[:class].to_s.split, "chart-tooltip"
      assert_includes tooltip[:class].to_s.split, "z-50"

      svg.send_keys(:arrow_right)
      assert_not_equal first, tooltip.text(:all), "the second press moves to the next date"

      svg.send_keys(:escape)
      assert_no_selector "[data-controller='loan-payoff-chart'] div[aria-live='polite']", visible: :all

      # A pointer sweep shows the tooltip but never turns it into a live region.
      page.execute_script(<<~JS)
        const rect = document.querySelector("[data-controller='loan-payoff-chart'] svg rect[style*='cursor']");
        const box = rect.getBoundingClientRect();
        rect.dispatchEvent(new PointerEvent("pointermove", { clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, bubbles: true }));
      JS
      assert_selector "[data-controller='loan-payoff-chart'] div.chart-tooltip", text: I18n.t("UI.account.chart.loan.scheduled")
      assert_no_selector "[data-controller='loan-payoff-chart'] div[aria-live='polite']", visible: :all
    end
  end

  # The tooltip formats its date and its money in the request's locale, which
  # the payload carries because the layout hard-codes `lang="en"`. Asserted
  # against what the browser's own Intl produces for German, so the expected
  # strings are not guessed; and against the English forms, so a formatter
  # that ignored the locale would fail here.
  test "the tooltip is formatted in the user's locale" do
    @user.update!(locale: "de")

    travel_to TODAY do
      account = on_contract_loan_account

      visit account_path(account, period: "all_time")
      svg = find("[data-controller='loan-payoff-chart'] svg")
      svg.send_keys(:arrow_right)
      tooltip = find("[data-controller='loan-payoff-chart'] div[aria-live='polite']", visible: :all)
      # The tooltip is one div per line; Capybara joins them without separators.
      text = tooltip.text(:all)

      german_date = page.evaluate_script("new Intl.DateTimeFormat('de', { month: 'short', year: 'numeric' }).format(new Date(2026, 0, 1))")
      german_money = page.evaluate_script("new Intl.NumberFormat('de', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(500000)")
      assert text.start_with?(german_date), "expected the tooltip to open with #{german_date.inspect}, got #{text.inspect}"
      assert_not text.start_with?("Jan 2026"), "d3's English month name must not leak through"
      # Intl separates the number and the symbol with a no-break space that
      # Capybara's text normalises to a plain one; compare on plain spaces.
      assert_includes text.gsub(/[[:space:]]/, " "), german_money.gsub(/[[:space:]]/, " ")
      assert_not_includes text, "$500,000", "the English money format must not leak through"
    end
  end

  private
    def assert_series_painted
      SERIES.each do |key|
        path = find("[data-controller='loan-payoff-chart'] svg path[data-series='#{key}']")

        assert path["d"].to_s.start_with?("M"), "the #{key} line has no geometry"
        assert_not_equal "none", stroke_of(key),
          "the #{key} line has geometry but no resolved stroke, so it does not mark the screen -- #101 exactly"
      end
      # The greyed remainder of the recorded line is a token too; it must
      # resolve without any fallback colour in the controller.
      shadow = page.evaluate_script("getComputedStyle(document.querySelector(\"svg path[data-series-shadow='actual']\")).stroke")
      assert_not_equal "none", shadow, "the greyed recorded line has no resolved stroke"
    end

    # `stroke: none` is the initial value, and it is what an unresolvable
    # colour leaves behind -- the whole point of reading the computed style
    # rather than the attribute we wrote.
    def stroke_of(key)
      page.evaluate_script(
        "getComputedStyle(document.querySelector(\"svg path[data-series='#{key}']\")).stroke"
      )
    end

    # Capybara retries its own matchers; a value read through evaluate_script
    # gets no such patience, so give it the same budget.
    def wait_until(timeout: Capybara.default_max_wait_time)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    def all_time_period
      Period.new(key: "all_time", start_date: Date.new(2020, 1, 1), end_date: TODAY)
    end

    # Built the way the account form builds one: with an opening valuation
    # for the amount borrowed. Without it Loan#original_balance falls back to
    # the current balance, and a loan part-way through its term would appear
    # to have borrowed only what it still owes.
    def loan_account
      account = Account.create!(
        family: @user.family, name: "Payoff Chart Loan",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 24,
                              rate_type: "fixed", start_date: Date.new(2026, 1, 1))
      )
      account.entries.create!(
        date: Date.new(2026, 1, 1), name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account
    end

    # A borrower exactly on contract, with the balance history the chart's
    # recorded line is drawn from. The projection then has somewhere to go; a
    # loan whose balance has run away has no payoff date at all, which is a
    # different test.
    def on_contract_loan_account
      account = loan_account
      rows = account.loan.amortization_schedule.payments.select { |p| p.date <= TODAY }
      account.update!(balance: rows.last.ending_balance.amount)
      account.balances.delete_all
      account.balances.create!(date: Date.new(2026, 1, 1), balance: 500_000, currency: "USD",
                               start_cash_balance: 500_000, flows_factor: -1)
      rows.each do |row|
        account.balances.create!(date: row.date, balance: row.ending_balance.amount, currency: "USD",
                                 start_cash_balance: row.ending_balance.amount, flows_factor: -1)
      end
      account.reload
    end
end
