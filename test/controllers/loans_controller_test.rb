require "test_helper"

class LoansControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  test "creates with loan details" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post loans_path, params: {
        account: {
          name: "New Loan",
          balance: 50000,
          currency: "USD",
          institution_name: "Local Bank",
          institution_domain: "localbank.example",
          notes: "Mortgage notes",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "mortgage",
            interest_rate: 5.5,
            term_months: 60,
            rate_type: "fixed",
            initial_balance: 50000
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Loan", created_account.name
    assert_equal 50000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Local Bank", created_account[:institution_name]
    assert_equal "localbank.example", created_account[:institution_domain]
    assert_equal "Mortgage notes", created_account[:notes]
    assert_equal "mortgage", created_account.accountable.subtype
    assert_equal 5.5, created_account.accountable.interest_rate
    assert_equal 60, created_account.accountable.term_months
    assert_equal "fixed", created_account.accountable.rate_type
    assert_equal 50000, created_account.accountable.initial_balance

    assert_redirected_to created_account
    assert_equal "Loan account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with loan details" do
    assert_no_difference [ "Account.count", "Loan.count" ] do
      patch loan_path(@account), params: {
        account: {
          name: "Updated Loan",
          balance: 45000,
          currency: "USD",
          institution_name: "Updated Bank",
          institution_domain: "updatedbank.example",
          notes: "Updated loan notes",
          accountable_type: "Loan",
          accountable_attributes: {
            id: @account.accountable_id,
            subtype: "auto",
            interest_rate: 4.5,
            term_months: 48,
            rate_type: "fixed",
            initial_balance: 48000
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Loan", @account.name
    assert_equal 45000, @account.balance
    assert_equal "Updated Bank", @account[:institution_name]
    assert_equal "updatedbank.example", @account[:institution_domain]
    assert_equal "Updated loan notes", @account[:notes]
    assert_equal "auto", @account.accountable.subtype
    assert_equal 4.5, @account.accountable.interest_rate
    assert_equal 48, @account.accountable.term_months
    assert_equal "fixed", @account.accountable.rate_type
    assert_equal 48000, @account.accountable.initial_balance

    assert_redirected_to @account
    assert_equal "Loan account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "renders the amortization schedule tab for a fixed rate loan" do
    get account_path(@account, tab: "schedule")

    assert_response :success
    # The chart card above the tabs carries its own data table (#100), so the
    # count is scoped to the schedule's table.
    chart_table = ActionView::RecordIdentifier.dom_id(@account, :loan_chart_table)
    assert_select "table:not(##{chart_table}) tbody tr", count: @account.loan.term_months
    assert_match "Total Interest", response.body
  end

  # A variable loan IS amortizable since #104, and a provider's own rate type
  # reads as variable since #100 decision 8, so the unamortizable case is now
  # a loan with no rate type at all.
  test "hides the schedule tab when the loan cannot be amortized" do
    @account.loan.update!(rate_type: "")

    get account_path(@account, tab: "schedule")

    assert_response :success
    assert_select "table tbody tr", count: 0
  end

  test "records rate changes and an origination date submitted through the form" do
    patch loan_path(@account), params: {
      account: {
        accountable_attributes: {
          id: @account.loan.id,
          rate_type: "variable",
          start_date: "2024-03-15",
          rate_changes: [
            { effective_date: "2026-04-01", rate: "7.25" },
            { effective_date: "2026-10-01", rate: "6.5" },
            { effective_date: "", rate: "" }
          ]
        }
      }
    }

    @account.loan.reload
    assert_equal({ "2026-04-01" => "7.25", "2026-10-01" => "6.5" }, @account.loan.variable_rate_schedule,
      "the wholly blank sentinel row must be dropped rather than persisted or raising")
    assert_equal Date.new(2024, 3, 15), @account.loan.start_date
    assert_equal Date.new(2024, 3, 15), @account.loan.origination_date
  end

  test "the schedule tab reflects a recorded rate change" do
    @account.loan.update!(rate_type: "variable", interest_rate: 6, term_months: 24)

    get account_path(@account, tab: "schedule")
    flat_payments = schedule_table_cells

    # A year into the 24-month term, whatever today is. The fixture loan has no
    # start_date, so its origination moves with the clock; a fixed date would
    # fall before the first payment once the calendar passed it, and the
    # schedule would stop re-amortising.
    change_date = @account.loan.origination_date >> 12
    @account.loan.update!(variable_rate_schedule: { change_date.iso8601 => "18.0" })
    get account_path(@account, tab: "schedule")

    assert_response :success
    # The schedule's own cells, not the whole body: the chart card above the
    # tabs carries its own data table, which moves for the same change.
    assert_equal flat_payments.length, schedule_table_cells.length
    assert_not_equal flat_payments, schedule_table_cells,
      "recording a rate change must change the payments the schedule tab renders"
    # A substring free of characters ERB escapes -- the full string contains an
    # apostrophe and renders as &#39;.
    assert_match "re-amortises at each recorded change", response.body
    assert_match I18n.t("loans.tabs.schedule.opening_payment"), response.body,
      "a re-amortising schedule must not label its first payment as THE monthly payment"
  end

  # #100 decision 8: a provider writes rate types the form never offers. The
  # select must still carry the loan's own value, or the browser submits the
  # first option and saving any other field turns an "arm" loan into a fixed
  # one without anyone choosing that.
  test "the edit form keeps a provider-written rate type as the selected option" do
    @account.loan.update!(rate_type: "arm")

    get edit_loan_path(@account)

    assert_response :success
    assert_select "select[name='account[accountable_attributes][rate_type]'] option[value='arm'][selected]", { count: 1 },
      "the provider's rate type must be the selected option"
    assert_select "select[name='account[accountable_attributes][rate_type]'] option[value='fixed']", count: 1
    assert_select "[data-loan-rate-changes-fixed-type-value='fixed']", count: 1
  end

  # A term the simulator will not walk leaves the loan without a schedule
  # (see Loan#amortizable?). The model stays tolerant because a provider writes
  # this column too; the form is where a person typing it is told the limit.
  test "the term input declares the range a schedule can be built for" do
    get edit_loan_path(@account)

    assert_response :success
    assert_select "input[name='account[accountable_attributes][term_months]'][min='1'][max='#{Loan::Simulator::MAX_PERIODS}']", count: 1
  end

  # A row with one half filled in is a typo, not a blank. Dropping it silently
  # loses what the user typed between submit and redisplay and never tells them
  # which row went.
  test "a half-filled rate change is rejected rather than silently dropped" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })

    patch loan_path(@account), params: {
      account: { accountable_attributes: {
        id: @account.loan.id, rate_type: "variable",
        rate_changes: [ { effective_date: "", rate: "9" } ]
      } }
    }

    # Asserted on the response, not on a Loan rebuilt in the test: a redirect
    # with the schedule untouched would otherwise pass.
    assert_response :unprocessable_entity
    assert_equal({ "2026-04-01" => "7.25" }, @account.loan.reload.variable_rate_schedule,
      "a rejected submission must not alter the persisted schedule")
    assert_select "input[name='account[accountable_attributes][rate_changes][][rate]'][value='9']", { count: 1 },
      "the typed row comes back so the form can redisplay it"
  end

  # Removing every row must clear the schedule. Without the form's blank
  # sentinel the PATCH carries no rate_changes key at all, nested assignment
  # never calls the writer, and the removed rows stay persisted.
  test "submitting only the blank sentinel clears the schedule" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })

    # The sentinel is a bare `rate_changes[]=` with no value, which Rack parses
    # as "" and strong parameters drop, so the writer receives an empty array.
    patch loan_path(@account), params: {
      account: { accountable_attributes: {
        id: @account.loan.id, rate_type: "variable", rate_changes: [ "" ]
      } }
    }

    assert_empty @account.loan.reload.variable_rate_schedule
  end

  # Reads the payload off the mounted controller's own data attribute rather
  # than parsing rendered SVG paths, which would be a brittle way to assert on
  # data that already has model-level coverage. This test's job is to prove the
  # right payload reaches the browser and mounts the controller.
  def chart_payload
    node = css_select("[data-controller='loan-payoff-chart']").first
    node && JSON.parse(node["data-loan-payoff-chart-data-value"])
  end

  # #100: the chart lives at the top of the account page, inside the chart
  # card's Turbo frame, on whichever tab is open. The Schedule tab keeps its
  # table and cards and no longer carries a chart of its own.
  test "the account page mounts the loan balance chart with its three series" do
    # All three lines need somewhere to be: a period that reaches past today
    # for the forecasts, and a recorded history for the actual line. The
    # earlier intersection assertion here passed with `visible` empty.
    origination = Date.current.prev_year
    @account.loan.update!(start_date: origination)
    @account.balances.create!(date: origination, balance: 500_000, currency: "USD",
                              start_cash_balance: 500_000, flows_factor: -1)
    @account.balances.create!(date: Date.current, balance: 490_000, currency: "USD",
                              start_cash_balance: 490_000, flows_factor: -1)

    get account_path(@account, period: "all_time")

    assert_response :success
    payload = chart_payload
    assert payload["scheduled"].length > 1
    assert payload["projected"].length > 1
    assert_equal %w[actual projected scheduled], payload.fetch("visible").sort
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@account, :chart_details)} [data-controller='loan-payoff-chart']", count: 1
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@account, :chart_details)} table", count: 1
  end

  test "the schedule tab renders its table without a chart of its own" do
    get account_path(@account, tab: "schedule")

    assert_response :success
    assert_select "[data-controller='loan-payoff-chart']", { count: 1 }, "one chart on the page, in the chart card"
    assert_select "table", { minimum: 2 }, "the schedule table and the chart's data table"
  end

  # A stray what-if parameter from an old link must change nothing: the
  # feature is not in this tranche (#100 decision 10).
  test "an extra-payment parameter is ignored" do
    get account_path(@account)
    baseline = chart_payload
    get account_path(@account, extra_payment: { amount: "2000", frequency: "monthly" })

    assert_response :success
    assert_equal baseline, chart_payload
  end

  test "a loan with no schedule renders the page without a loan chart" do
    @account.loan.update!(rate_type: "")

    get account_path(@account)

    assert_response :success
    assert_nil chart_payload
    assert_select "[data-controller='time-series-chart']", count: 1
  end
  # The validation lives on Loan and is reached through nested attributes, which
  # validate the nested record only when it has changes. Resubmitting the stored
  # rows plus a typo'd one leaves the column equal to its stored value, so
  # without `Loan#changed_for_autosave?` the account saved with a 302 and the
  # typo'd row vanished.
  test "an invalid row is rejected even when nothing else on the loan changed" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })

    patch loan_path(@account), params: { account: { accountable_attributes: {
      id: @account.loan.id, rate_type: "variable",
      rate_changes: [ "", { effective_date: "2026-04-01", rate: "7.25" }, { effective_date: "", rate: "9" } ]
    } } }

    assert_response :unprocessable_entity
    assert_select "input[name='account[accountable_attributes][rate_changes][][rate]'][value='9']", { count: 1 },
      "the typed row must come back for correction"
    assert_equal({ "2026-04-01" => "7.25" }, @account.loan.reload.variable_rate_schedule)
  end

  # Retained rows are rendered for a fixed loan too, hidden and disabled, so
  # switching the select to variable reveals them and a save keeps them.
  # Before this, `rate_change_rows` was empty for a fixed loan, the revealed
  # section was empty, and saving sent only the sentinel, which cleared them.
  test "a fixed loan's retained rate changes survive switching to variable and saving" do
    @account.loan.update!(rate_type: "fixed", variable_rate_schedule: { "2026-04-01" => "7.25" })

    get edit_loan_path(@account)

    assert_response :success
    assert_select "[data-loan-rate-changes-target=rows] [data-rate-change-row]", count: 1
    assert_select "[data-loan-rate-changes-target=rows] input[disabled][value='2026-04-01']", { count: 1 },
      "retained rows are disabled while the loan is fixed, so they are not submitted"

    # What the browser sends after the select is flipped to variable and the
    # inputs are enabled: the sentinel and the row it rendered.
    patch loan_path(@account), params: { account: { accountable_attributes: {
      id: @account.loan.id, rate_type: "variable",
      rate_changes: [ "", { effective_date: "2026-04-01", rate: "7.25" } ]
    } } }

    assert_equal({ "2026-04-01" => "7.25" }, @account.loan.reload.variable_rate_schedule)
    assert_equal "variable", @account.loan.rate_type
  end

  # `disabled` used to be applied only by Stimulus, so without JavaScript the
  # sentinel submitted and the writer read it as "remove them all".
  test "the edit form of a fixed loan disables the whole rate-change section server-side" do
    @account.loan.update!(rate_type: "fixed", variable_rate_schedule: { "2026-04-01" => "7.25" })

    get edit_loan_path(@account)

    assert_select "[data-loan-rate-changes-target=section][hidden]", count: 1
    assert_select "[data-loan-rate-changes-target=section] input[name='account[accountable_attributes][rate_changes][]'][disabled]", { count: 1 },
      "the sentinel must be disabled too, or a no-JS save clears the schedule"
    # The <template> clone is inert and is left enabled; only rendered rows and
    # the add button are submittable.
    assert_select "[data-loan-rate-changes-target=rows] input:not([disabled])", count: 0
    assert_select "[data-loan-rate-changes-target=rows] button:not([disabled])", count: 0
    assert_select "[data-loan-rate-changes-target=section] > button:not([disabled])", count: 0
  end

  test "a variable loan's edit form enables the rate-change section server-side" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })

    get edit_loan_path(@account)

    assert_select "[data-loan-rate-changes-target=section][hidden]", count: 0
    assert_select "[data-loan-rate-changes-target=rows] input[disabled]", count: 0
    assert_select "[data-loan-rate-changes-target=section] input[name='account[accountable_attributes][rate_changes][]']:not([disabled])", count: 1
  end

  # The payload runs the schedule, the projection and a balance query on every
  # loan page view, from provider-written and user-written inputs. A raise in
  # any of them must cost the chart, not the page: before this guard the whole
  # account page was a 500 for a loan that rendered fine without the chart.
  test "a chart payload that raises degrades to the time-series chart instead of a 500" do
    Loan::PayoffChart.any_instance.stubs(:payload).raises(ArgumentError, "boom")

    get account_path(@account, tab: "schedule")

    assert_response :success
    assert_select "[data-controller='time-series-chart']", count: 1
    assert_select "[data-controller='loan-payoff-chart']", count: 0
    assert_match "Total Interest", response.body, "the Schedule tab still renders"
  end

  # `Account.create_and_sync` saves with `save!`, and this is the first Loan
  # validation a user can trip from the create form. Without a rescue the
  # request ended on the generic 422 error page and the form was gone.
  test "a half-filled rate change on create re-renders the form instead of the error page" do
    assert_no_difference [ "Account.count", "Loan.count" ] do
      post loans_path, params: { account: {
        name: "Bad Loan", balance: 50_000, currency: "USD", accountable_type: "Loan",
        accountable_attributes: {
          rate_type: "variable", interest_rate: 6, term_months: 12, initial_balance: 50_000,
          rate_changes: [ "", { effective_date: "", rate: "9" } ]
        }
      } }
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{loans_path}']", count: 1, message: "the new-loan form comes back"
    assert_select "input[name='account[accountable_attributes][rate_changes][][rate]'][value='9']", count: 1
    assert_match "effective date and a rate", response.body
  end

  # The Overview tab quoted `loans.interest_rate`, the origination rate, while
  # the Schedule tab beside it re-amortised at each recorded change.
  test "the overview tab shows the rate in force, not the origination rate" do
    @account.loan.update!(rate_type: "variable", interest_rate: 6,
                          variable_rate_schedule: { (Date.current - 1.month).iso8601 => "7.25" })

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "h4", text: I18n.t("loans.tabs.overview.interest_rate")
    assert_match "7.250%", response.body, "the recorded change is the rate in force"
    assert_no_match "6.000%", response.body, "the origination rate is not what the loan is charging"
    assert_match I18n.t("loans.tabs.overview.not_applicable"), response.body,
      "a variable loan has no single monthly payment"
  end

  test "the overview tab of a fixed loan still shows its rate and monthly payment" do
    @account.loan.update!(rate_type: "fixed", interest_rate: 6, term_months: 360)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_match "6.000%", response.body
    # 500,000 at 6% over 360 months, the fixture loan's contracted repayment.
    assert_match "2,997.75", response.body
  end

  # Brief 7.4 row 8: the period picker re-renders the chart card's frame, and
  # the cards and the mount must both live inside it.
  test "a chart_details frame request carries the mount and both cards inside the frame" do
    frame_id = ActionView::RecordIdentifier.dom_id(@account, :chart_details)

    get account_path(@account, period: "all_time"), headers: { "Turbo-Frame" => frame_id }

    assert_response :success
    assert_select "turbo-frame##{frame_id} [data-controller='loan-payoff-chart']", count: 1
    assert_select "turbo-frame##{frame_id} h4", text: I18n.t("UI.account.chart.loan.projected_payoff"), count: 1
    assert_select "turbo-frame##{frame_id} h4", text: I18n.t("UI.account.chart.loan.interest_saved"), count: 1
  end

  # The activity feed paginates through its own `entries` frame. That request
  # renders the whole page and keeps one frame, so building the chart payload
  # for it ran a full simulation per page turn for nothing.
  test "a frame request outside the chart card does not build the chart payload" do
    Loan::PayoffChart.any_instance.expects(:payload).never

    get account_path(@account, page: 2), headers: { "Turbo-Frame" => ActionView::RecordIdentifier.dom_id(@account, "entries") }

    assert_response :success
  end

  test "the account's container frame request still builds the chart payload" do
    get account_path(@account, period: "all_time"), headers: { "Turbo-Frame" => ActionView::RecordIdentifier.dom_id(@account, :container) }

    assert_response :success
    assert_select "[data-controller='loan-payoff-chart']", count: 1
  end

  # Codex on we-promise/sure#3473: `update` persisted the balance change (a
  # valuation and the account's cached balance) before the loan's validation
  # ran, so a rejected form had committed half of itself.
  test "a rejected update does not persist the balance change submitted with it" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })
    balance_before = @account.reload.balance

    assert_no_difference "Entry.count" do
      patch loan_path(@account), params: { account: {
        balance: balance_before - 10_000,
        accountable_attributes: {
          id: @account.loan.id, rate_type: "variable",
          rate_changes: [ "", { effective_date: "2026-04-01", rate: "7.25" }, { effective_date: "", rate: "9" } ]
        }
      } }
    end

    assert_response :unprocessable_entity
    assert_equal balance_before, @account.reload.balance, "the balance half of a rejected form must not commit"
  end

  # CodeRabbit on we-promise/sure#3474: `lock_saved_attributes!` saves with
  # `update!`. Run after the transaction had committed, a raise there left the
  # balance change and the attribute update in place behind a failed request.
  test "an update whose attribute lock fails commits neither the balance nor the attributes" do
    balance_before = @account.reload.balance
    name_before = @account.name
    Account.any_instance.stubs(:lock_saved_attributes!).raises(ActiveRecord::RecordInvalid.new(@account))

    assert_no_difference "Entry.count" do
      patch loan_path(@account), params: { account: { name: "Renamed Loan", balance: balance_before - 10_000 } }
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{loan_path(@account)}']", count: 1
    assert_equal balance_before, @account.reload.balance, "the balance must roll back with the failed lock"
    assert_equal name_before, @account.name, "the attribute update must roll back with the failed lock"
  end

  # CodeRabbit on we-promise/sure#3473: `loans/new` renders the method
  # selector when `step=method_select`, which reads `@provider_configs`; the
  # rescue path must set it up as `new` does.
  test "a rejected create with the method-select step still renders" do
    post loans_path(step: "method_select"), params: { account: {
      name: "Bad Loan", balance: 50_000, currency: "USD", accountable_type: "Loan",
      accountable_attributes: { rate_type: "variable", interest_rate: 6, term_months: 12, initial_balance: 50_000,
                                rate_changes: [ "", { effective_date: "", rate: "9" } ] }
    } }

    assert_response :unprocessable_entity
  end

  test "the rate-change controls are design-system buttons" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })

    get edit_loan_path(@account)

    assert_select "button[data-action='loan-rate-changes#add'] span", text: I18n.t("loans.form.rate_change_add")
    assert_select "[data-rate-change-row] button[data-action='loan-rate-changes#remove'] span", text: I18n.t("loans.form.rate_change_remove")
  end

  # The design-system guide asks inputs to take the form's field shape. The rows
  # were bare inputs outside any .form-field, so they rendered with no field
  # border and no visible label. The partial is also the Stimulus clone
  # template, so each label wraps its input rather than pointing at an id that
  # every cloned row would repeat.
  test "each rate-change input is a labelled form field without an id" do
    @account.loan.update!(rate_type: "variable", variable_rate_schedule: { "2026-04-01" => "7.25" })

    get edit_loan_path(@account)

    assert_response :success
    rows = "[data-loan-rate-changes-target=rows] [data-rate-change-row]"
    assert_select "#{rows} .form-field label", count: 2
    assert_select "#{rows} .form-field label input[type=date][value='2026-04-01']", count: 1
    assert_select "#{rows} .form-field label input[type=number][value='7.25']", count: 1
    assert_select "#{rows} .form-field__label", text: I18n.t("loans.form.rate_change_effective_date")
    assert_select "#{rows} .form-field__label", text: I18n.t("loans.form.rate_change_rate")
    # Unscoped on purpose: the <template> copy is the one every added row clones.
    assert_select "[data-rate-change-row] input[id]", count: 0
  end

  # CodeRabbit on we-promise/sure#3473: `create_and_sync` can raise RecordInvalid
  # from the opening valuation's `entries.create!` or from `lock_saved_attributes!`,
  # and then `e.record` is an Entry or the accountable, not the account the form
  # renders.
  test "a create that fails on the opening valuation still re-renders the form" do
    invalid_entry = Entry.new.tap(&:validate)
    Account::OpeningBalanceManager.any_instance.stubs(:set_opening_balance)
      .raises(ActiveRecord::RecordInvalid.new(invalid_entry))

    assert_no_difference "Account.count" do
      post loans_path, params: { account: {
        name: "Loan With Bad Anchor", balance: 50_000, currency: "USD", accountable_type: "Loan",
        accountable_attributes: { rate_type: "fixed", interest_rate: 6, term_months: 12, initial_balance: 50_000 }
      } }
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{loans_path}']", count: 1
    # Rebuilt from the submission, not a blank account: what was typed comes
    # back for correction.
    assert_select "input[name='account[name]'][value='Loan With Bad Anchor']", count: 1
    assert_select "input[name='account[accountable_attributes][interest_rate]'][value='6']", count: 1
  end

  private
    # The payment cells of the Schedule tab's table, leaving out the chart
    # card's data table that sits above the tabs.
    def schedule_table_cells
      chart_table = ActionView::RecordIdentifier.dom_id(@account, :loan_chart_table)
      css_select("table:not(##{chart_table}) tbody td").map { |cell| cell.text.strip }
    end
end
