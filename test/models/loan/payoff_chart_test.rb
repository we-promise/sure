require "test_helper"

class Loan::PayoffChartTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2027, 1, 15)
    # What the picker hands over for "All" on @today. The real all-time period
    # ends on Date.current, and these tests sit on a pinned date.
    @all_time = Period.new(key: "all_time", start_date: Date.new(2020, 1, 1), end_date: @today)
  end

  test "carries the recorded balance, the original schedule and the projection" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert payload[:actual].length > 1
    assert payload[:scheduled].length > 1
    assert payload[:projected].length > 1
    assert_equal %w[actual scheduled projected], payload[:visible].map(&:to_s)
    assert_equal @today.iso8601, payload[:today]
    assert_equal "USD", payload[:currency]
    assert_not payload.key?(:accelerated), "the what-if left this tranche (#100 decision 10)"
  end

  # The amount borrowed is the first thing a payoff chart should show, and
  # every point after it is the schedule's own row for that date.
  test "the scheduled series is the schedule, opening at origination with the full principal" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload
    rows = loan.amortization_schedule.payments.index_by { |row| row.date.iso8601 }

    assert_equal loan.origination_date.iso8601, payload[:scheduled].first[:date]
    assert_equal loan.amortization_schedule.principal.to_f, payload[:scheduled].first[:balance]
    payload[:scheduled].drop(1).each do |point|
      assert_equal rows.fetch(point[:date]).ending_balance.amount.to_f, point[:balance],
        "the scheduled point on #{point[:date]} must be the schedule's own row"
    end
    assert_equal loan.amortization_schedule.payoff_date.iso8601, payload[:scheduled].last[:date]
  end

  test "the projection opens at today's real balance" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert_equal @today.iso8601, payload[:projected].first[:date]
    assert_equal loan.account.balance.to_f, payload[:projected].first[:balance]
  end

  # Owner review of #3474: a timescale picked on a loan's chart runs forward
  # from origination -- 1Y is the loan's first year -- rather than back from
  # today. The recorded series still ends at today or at the window's end,
  # whichever comes first, and never starts before origination. Queried past
  # today it would carry today's balance forward as a flat line.
  test "the actual series ends at the earlier of today and the window's end, in the loan's currency" do
    loan = on_contract_loan

    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload
    assert_equal @today.iso8601, whole_life[:actual].last[:date]
    assert_operator Date.iso8601(whole_life[:actual].first[:date]), :>=, loan.origination_date

    ninety_days = Period.new(key: "last_90_days", start_date: @today - 90, end_date: @today)
    clipped = Loan::PayoffChart.new(loan, as_of: @today, period: ninety_days).payload
    window_end = loan.origination_date + 90
    assert_equal window_end.iso8601, clipped[:actual].last[:date]
    assert clipped[:actual].all? { |point| Date.iso8601(point[:date]).between?(loan.origination_date, window_end) }

    assert_equal "USD", clipped[:currency]
    assert_equal loan.account.balance.to_f, whole_life[:actual].last[:balance],
      "the recorded balance is read in the loan's own currency, so no exchange rate applies"
  end

  # The loan chart's windows: M is the first month, 90D the first ninety days,
  # YTD origination to today, 1Y, 5Y and 10Y the first years. None runs past
  # the later payoff, where All ends.
  test "the domain runs forward from origination: the whole life under All, the chosen window otherwise" do
    loan = on_contract_loan
    start = loan.origination_date
    whole_life_end = [ loan.amortization_schedule.payoff_date, loan.payoff_projection(as_of: @today).payoff_date ].max
    window = ->(key) { Period.new(key: key, start_date: @today - 30, end_date: @today) }

    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload
    assert_equal start.iso8601, whole_life[:domain_start]
    assert_equal whole_life_end.iso8601, whole_life[:domain_end]

    {
      "current_month" => start >> 1,
      "last_90_days" => start + 90,
      "current_year" => @today,
      "last_365_days" => start >> 12,
      "last_5_years" => whole_life_end
    }.each do |key, expected_end|
      windowed = Loan::PayoffChart.new(loan, as_of: @today, period: window.(key)).payload
      assert_equal start.iso8601, windowed[:domain_start], "#{key} must start at origination, not count back from today"
      assert_equal expected_end.iso8601, windowed[:domain_end], "#{key} must end on #{expected_end}"
    end
  end

  # Under a window that ends by today the projection has at most one point
  # inside the domain -- today -- and a point is not a line. The legend must not
  # promise one; a window that reaches past today draws it.
  test "forward series are visible only when the window reaches past today" do
    loan = on_contract_loan
    window = ->(key) { Period.new(key: key, start_date: @today - 30, end_date: @today) }

    to_date = Loan::PayoffChart.new(loan, as_of: @today, period: window.("current_year")).payload
    assert_equal %w[actual scheduled], to_date[:visible].map(&:to_s)
    assert to_date[:projected].length > 1, "the series is still in the payload; only its legend entry is withheld"

    first_five_years = Loan::PayoffChart.new(loan, as_of: @today, period: window.("last_5_years")).payload
    assert_includes first_five_years[:visible].map(&:to_s), "projected"
  end

  # The picker's choice is shared with every account, so a loan page can be
  # opened under a period its chart does not offer. That shows the whole life.
  test "a saved period the loan chart does not offer shows the loan's whole life" do
    loan = on_contract_loan
    whole_life = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload

    %w[last_7_days last_30_days current_week last_month].each do |key|
      period = Period.new(key: key, start_date: @today - 30, end_date: @today)
      payload = Loan::PayoffChart.new(loan, as_of: @today, period: period).payload
      assert_equal whole_life.values_at(:domain_start, :domain_end), payload.values_at(:domain_start, :domain_end),
        "#{key} is not a loan window, so the chart shows the whole life"
    end
  end

  # WINDOWS is looked up by the saved Period key. A key that is not a real
  # Period key would never match, and that window would silently show the
  # whole life instead.
  test "every loan window is a shared period key" do
    assert_empty Loan::PayoffChart::WINDOWS.keys - Period::PERIODS.keys,
      "loan chart windows must use Period::PERIODS keys"
  end

  # Overlapping the schedule IS the on-track picture; the projection is not
  # withheld for agreeing with the contract.
  test "the projection is drawn when it overlaps the schedule and withheld only when it cannot run" do
    on_track = Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload
    assert on_track[:projected].length > 1
    assert_includes on_track[:visible].map(&:to_s), "projected"

    cleared = build_loan
    cleared.account.update!(balance: 0)
    paid_off = Loan::PayoffChart.new(cleared.reload, as_of: @today).payload
    assert_empty paid_off[:projected]
    assert_not_includes paid_off[:visible].map(&:to_s), "projected"
  end

  # A loan drawn down today has one recorded point at most and no history to
  # compare against; the page must still render.
  test "a loan originated today renders a valid payload with no exception" do
    # Created on the pinned day itself: an origination date may not lie in the
    # future, and @today is ahead of the calendar.
    account = travel_to(@today) do
      Account.create!(
        family: @family, name: "New Loan", balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 24,
                              rate_type: "fixed", start_date: @today)
      )
    end
    account.balances.create!(date: @today, balance: 500_000, currency: "USD",
                             start_cash_balance: 500_000, flows_factor: -1)

    payload = Loan::PayoffChart.new(account.loan, as_of: @today, period: @all_time).payload

    assert_equal @today.iso8601, payload[:scheduled].first[:date]
    assert_equal @today.iso8601, payload[:domain_start]
    assert_operator payload[:actual].length, :<=, 1
    assert_not_includes payload[:visible].map(&:to_s), "actual", "one point is not a line"
    assert_includes payload[:visible].map(&:to_s), "projected"
  end

  test "no payload at all for a loan with no schedule" do
    loan = build_loan(rate_type: "")

    assert_nil Loan::PayoffChart.new(loan, as_of: @today).payload
  end

  test "a loan with no recorded balances yet draws no actual series and does not raise" do
    loan = build_loan
    loan.account.balances.delete_all

    payload = Loan::PayoffChart.new(loan.reload, as_of: @today).payload

    assert_empty payload[:actual]
    assert payload[:scheduled].length > 1
  end

  test "the accessible description names the balance and each payoff date separately" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today).payload
    schedule = loan.amortization_schedule
    projection = loan.payoff_projection(as_of: @today)

    assert_includes payload[:aria_description], projection.current_balance.format
    assert_includes payload[:aria_description], I18n.l(schedule.payoff_date, format: :long)
    assert_includes payload[:aria_description], I18n.l(projection.payoff_date, format: :long)
    assert_not_includes payload[:aria_description], I18n.t(
      "UI.account.chart.loan.aria_actual_history_starts",
      date: I18n.l(loan.origination_date, format: :long)
    )
  end

  test "the accessible description dates recorded history when it starts after origination" do
    loan = on_contract_loan
    first_recorded_date = loan.origination_date >> 6
    loan.account.balances.where(date: ...first_recorded_date).delete_all

    payload = Loan::PayoffChart.new(loan.reload, as_of: @today).payload

    assert_equal first_recorded_date.iso8601, payload[:actual].first[:date]
    assert_includes payload[:aria_description], I18n.t(
      "UI.account.chart.loan.aria_actual_history_starts",
      date: I18n.l(first_recorded_date, format: :long)
    )
  end

  test "German loan chart translations cover the English chart keys and windows" do
    english = I18n.t("UI.account.chart.loan", locale: :en)
    german = I18n.t("UI.account.chart.loan", locale: :de)

    assert_equal english.keys.sort, german.keys.sort
    assert_equal english.fetch(:windows).keys.sort, german.fetch(:windows).keys.sort
    assert_equal "10J", I18n.t("UI.account.chart.loan.windows.last_10_years", locale: :de)
  end

  # The chart controller sets aria-roledescription from labels.interactive_chart
  # and falls back to English when the payload does not carry it.
  test "the payload carries a localized interactive chart role description" do
    english = Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload
    assert_equal "interactive chart", english[:labels][:interactive_chart]

    german = I18n.with_locale(:de) { Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload }
    assert_equal "interaktives Diagramm", german[:labels][:interactive_chart]
  end

  # A borrower too far behind has no payoff date. The description must say so
  # rather than interpolating a bare nil into a sentence.
  test "the description says so when the contract no longer pays the loan off" do
    loan = build_loan
    loan.account.update!(balance: 400_000)

    payload = Loan::PayoffChart.new(loan, as_of: @today).payload

    assert_nil payload[:projected_payoff_date]
    assert_match I18n.t("UI.account.chart.loan.no_payoff"), payload[:aria_description]
    # The balloon travels with the payload for the notice; on a loan that does
    # pay off it is nil, so a card is never quoted a figure of zero.
    assert_operator payload[:balloon], :>, 0
    assert_nil Loan::PayoffChart.new(on_contract_loan, as_of: @today).payload[:balloon]
  end

  # Owner review of #3474: the chart has no data table any more; the Schedule
  # tab carries the figures, so the payload builds no rows for one.
  test "the payload carries no data table rows" do
    payload = Loan::PayoffChart.new(on_contract_loan, as_of: @today, period: @all_time).payload

    assert_not payload.key?(:rows), "nothing renders table rows, so the payload must not build them"
  end

  # Decision 4: the recorded series never starts before the loan does. A
  # balance row dated before origination (an account opened, then a loan
  # recorded against it later) must not become a lead-in, whatever window is
  # picked: every loan window opens at origination.
  test "the actual series never starts before origination, whatever the window" do
    loan = on_contract_loan
    loan.account.balances.create!(date: Date.new(2025, 12, 1), balance: 0, currency: "USD",
                                  start_cash_balance: 0, flows_factor: -1)
    first_year = Period.new(key: "last_365_days", start_date: @today - 365, end_date: @today)

    [ @all_time, first_year ].each do |period|
      payload = Loan::PayoffChart.new(loan.reload, as_of: @today, period: period).payload

      assert_equal loan.origination_date.iso8601, payload[:actual].first[:date],
        "the first recorded point is origination, not the pre-origination row (#{period.key})"
      assert payload[:actual].none? { |point| Date.iso8601(point[:date]) < loan.origination_date }
    end
  end

  # #100 acceptance criterion: the chart's endpoint and the card quote one date.
  test "the projected series ends on the projected payoff date" do
    loan = on_contract_loan
    payload = Loan::PayoffChart.new(loan, as_of: @today, period: @all_time).payload

    assert_equal payload[:projected_payoff_date], payload[:projected].last[:date]
    assert_equal payload[:scheduled_payoff_date], payload[:scheduled].last[:date]
  end

  # The layout hard-codes `lang="en"`, so the chart cannot learn the locale
  # from the document; the payload carries it for the tooltip's date and
  # money formatting (Codex on we-promise/sure#3474).
  test "the payload carries the request locale for the tooltip" do
    loan = on_contract_loan

    assert_equal "en", Loan::PayoffChart.new(loan, as_of: @today).payload[:locale]
    I18n.with_locale(:de) do
      assert_equal "de", Loan::PayoffChart.new(loan, as_of: @today).payload[:locale]
    end
  end


  # jjmata on we-promise/sure#3474: the domain was recomputed for every plotted
  # point and table row, and for a loan with no start date each computation
  # looked origination up again -- about 4,400 statements for one page under
  # All. The work a payload does must not grow with the length of the schedule.
  test "building the payload does not repeat its lookups per scheduled payment" do
    short = build_undated_loan(term_months: 24)
    long = build_undated_loan(term_months: 360)

    short_count = sql_statements { Loan::PayoffChart.new(short, as_of: @today, period: @all_time).payload }
    long_count = sql_statements { Loan::PayoffChart.new(long, as_of: @today, period: @all_time).payload }

    assert_equal short_count, long_count,
      "a 360-payment schedule ran #{long_count} statements where a 24-payment one ran #{short_count}"
  end

  private
    # Every statement, including those the query cache answers: a cached
    # lookup still builds its relation and records.
    def sql_statements(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    # A loan with no recorded start date, as a loan created before the field
    # existed has: origination falls back to the account's first valuation.
    def build_undated_loan(term_months:)
      account = Account.create!(
        family: @family, name: "Undated Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: term_months, rate_type: "fixed")
      )
      account.entries.create!(
        date: Date.new(2026, 1, 1), name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      record_balances(account)
      account.loan
    end

    def build_loan(rate_type: "fixed")
      account = Account.create!(
        family: @family, name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: 6, term_months: 24,
                              rate_type: rate_type, start_date: Date.new(2026, 1, 1))
      )
      # The opening valuation the account form records: Loan#original_balance
      # reads it, and without it the principal would follow whatever the
      # current balance is later set to.
      account.entries.create!(
        date: Date.new(2026, 1, 1), name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      record_balances(account)
      account.loan
    end

    # Loans exactly on contract at `@today`. The schedule then agrees with the
    # recorded history and the projection has somewhere to go.
    def on_contract_loan
      loan = build_loan
      scheduled = loan.amortization_schedule.payments
        .select { |p| p.date <= @today }.last.ending_balance.amount
      loan.account.update!(balance: scheduled)
      record_balances(loan.account, through: @today, closing: scheduled)
      loan.reload
    end

    # Materialised balance rows the way the balance calculator writes them for
    # a liability: the outstanding amount in start_cash_balance with a -1 flows
    # factor, which Balance::ChartSeriesBuilder reads back as a positive debt.
    # One row a month from origination, following the schedule's balances so
    # the recorded history is a plausible loan rather than a flat line.
    def record_balances(account, through: Date.new(2026, 6, 30), closing: nil)
      account.balances.delete_all
      rows = (account.loan.amortization_schedule&.payments || []).select { |p| p.date <= through }
      account.balances.create!(date: Date.new(2026, 1, 1), balance: 500_000, currency: "USD",
                               start_cash_balance: 500_000, flows_factor: -1)
      rows.each do |row|
        account.balances.create!(date: row.date, balance: row.ending_balance.amount, currency: "USD",
                                 start_cash_balance: row.ending_balance.amount, flows_factor: -1)
      end
      return if closing.nil?

      account.balances.create!(date: through, balance: closing, currency: "USD",
                               start_cash_balance: closing, flows_factor: -1)
    end
end
