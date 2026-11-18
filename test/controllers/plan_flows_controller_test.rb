require "test_helper"

class PlanFlowsControllerTest < ActionDispatch::IntegrationTest
  # House pattern (bills_controller_test): session login + preview flag, and
  # the income/occurrence setup mirrors api/v1/paycheck_plans_controller_test
  # (dylan_family, family_admin/family_member, two November 2026 paychecks).
  teardown do
    travel_back
  end

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @other = users(:family_member)
    @account = accounts(:depository)
    ensure_tailwind_build
  end

  def create_income_series(account:, name:, amount:)
    series = @family.recurring_transactions.create!(
      name: name,
      account: account,
      amount: amount,
      currency: "USD",
      expected_day_of_month: 6,
      last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20),
      status: "active",
      bill_type: "income",
      manual: true
    )
    series.recurring_occurrences.destroy_all
    [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |date|
      series.recurring_occurrences.create!(family: @family, due_on: date,
        original_due_on: date, currency: "USD", expected_amount: amount,
        status: "scheduled")
    end
    series
  end

  test "add accounts assigns plan_order to the selected accounts" do
    a = @family.accounts.create!(name: "New A", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    b = @family.accounts.create!(name: "New B", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    base = @family.accounts.maximum(:plan_order).to_i

    post "/plan/flow_add_accounts", params: { account_ids: [ a.id, b.id ] }

    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal base + 1, a.reload.plan_order
    assert_equal base + 2, b.reload.plan_order
  end

  test "create account builds a manual bank on the map" do
    post "/plan/flow_create_account", params: {
      account: { name: "Manual Bank", institution_name: "Manual Trust" }
    }

    assert_redirected_to "/plan/flow?view=paycheck"
    account = @family.accounts.find_by(name: "Manual Bank")
    assert account, "the manual account was not created"
    assert_equal "Manual Trust", account.institution_name
    assert_equal "Depository", account.accountable_type
    assert_equal 0, account.balance
    assert account.plan_order.present?
  end

  test "create account with a blank name is rejected with a flash" do
    post "/plan/flow_create_account", params: { account: { name: "  " } }

    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.create_account.account_failed"), flash[:alert]
    assert_nil @family.accounts.find_by(name: "  ")
  end

  test "update account writes ownership from the combined dropdown" do
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "user:#{@other.id}" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "user", @account.reload.plan_ownership
    assert_equal @other.id, @account.plan_owner_user_id

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared" }
    }
    assert_equal "shared", @account.reload.plan_ownership
    assert_nil @account.plan_owner_user_id

    # A user outside the family falls back to shared/nil, not a 500.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "user:#{users(:empty).id}" }
    }
    assert_equal "shared", @account.reload.plan_ownership
    assert_nil @account.plan_owner_user_id
  end

  test "update account also moves plan_order from the card select" do
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_order: "7" }
    }
    assert_equal 7, @account.reload.plan_order
  end

  test "update income labels the series to a family member" do
    series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
    series.update!(plan_max_account_links: 5)

    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: @other.id }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal @other.id, series.reload.plan_owner_user_id
    # Omitting the limit param keeps the existing value (no silent wipe).
    assert_equal 5, series.plan_max_account_links

    # Blank clears the label back to the account-owner fallback.
    patch "/plan/flow/incomes/#{series.id}", params: { series: { plan_owner_user_id: "" } }
    assert_nil series.reload.plan_owner_user_id
  end

  # --- planning diagram JSON + allocation CRUD + bank/income config ---

  test "graph returns the saved state as JSON" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      PlanAllocation.create!(family: @family, account: @account, name: "Bills",
        kind: "bill", mode: "required", value_cents: 50_000, cadence: "monthly")

      get "/plan/flow/graph", params: { income: series.id }

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal 2, json["total_paychecks"]
      assert_equal %w[incomes banks allocations over_plans limit_warnings recommendations],
        %w[incomes banks allocations over_plans limit_warnings recommendations] & json.keys
      # Required value_cents is a MONTHLY figure prorated over the paychecks:
      # 500.00/month over 2 paychecks of 900.
      bills = json["allocations"].find { |a| a["name"] == "Bills" }
      assert_equal "500.00", bills["wanted_month"]
      assert_equal "500.00", bills["got_month"]
      assert_equal "250.00", bills["per_paycheck"].first["wanted"]
      assert_equal "ok", bills["status"]
      bank = json["banks"].find { |b| b["id"] == @account.id }
      assert_equal "1800.00", bank["inflow_month"]
      assert_equal "1300.00", bank["surplus_month"] # 1800 - 500
      assert_equal [], json["over_plans"]
      # netflix_subscription (15.99/mo) is not allocated yet -> recommended.
      assert json["recommendations"].any? { |r| r["type"] == "recurring_transaction" }
    end
  end

  test "graph merges draft edges and draft allocation rows over saved" do
    travel_to Date.new(2026, 11, 15) do
      series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
      IncomeAccountAllocation.create!(family: @family, income_series: series,
        account: @account, mode: "leftover")
      savings = @family.accounts.create!(name: "Savings", owner: @user, currency: "USD",
        balance: 0, accountable: Depository.new)

      # Draft: the selected income's leftover edge is replaced by a 100/pk
      # specific edge to Savings; a new unsaved fun row joins the saved set.
      get "/plan/flow/graph", params: {
        income: series.id,
        edges: { savings.id.to_s => { "enabled" => "1", "mode" => "specific", "value" => "100" } },
        allocations: {
          "new-1" => { "name" => "Fun", "kind" => "fun_money", "mode" => "specific",
                       "value" => "300", "account_id" => @account.id }
        }
      }

      assert_response :success
      json = JSON.parse(response.body)
      # The draft edge replaced the saved leftover edge: only Savings
      # receives funds, @account starves, and the draft fun row is unfunded.
      savings_bank = json["banks"].find { |b| b["id"] == savings.id }
      assert_equal "200.00", savings_bank["inflow_month"] # 100 x 2 paychecks
      assert_equal "0.00", json["banks"].find { |b| b["id"] == @account.id }["inflow_month"]
      fun = json["allocations"].find { |a| a["id"] == "new-1" }
      assert_equal "Fun", fun["name"]
      assert_equal "600.00", fun["wanted_month"] # 300 x 2 paychecks
      assert_equal "0.00", fun["got_month"]
      assert_equal "over", fun["status"]
    end
  end

  test "create allocation upserts by bank and name" do
    post "/plan/flow/allocations", params: {
      plan_allocation: { account_id: @account.id, name: "Netflix", kind: "bill",
                         mode: "specific", value: "15.99", cadence: "monthly" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.create_allocation.saved"), flash[:notice]
    row = @family.plan_allocations.find_by(name: "Netflix")
    assert row, "the allocation was not created"
    assert_equal 1599, row.value_cents.to_i

    # Re-saving the same bank + name edits the row instead of duplicating it.
    post "/plan/flow/allocations", params: {
      plan_allocation: { account_id: @account.id, name: "Netflix", kind: "bill",
                         mode: "specific", value: "20.00" }
    }
    assert_equal 1, @family.plan_allocations.count
    assert_equal 2000, row.reload.value_cents.to_i
  end

  test "create allocation flashes the house alert on invalid values" do
    post "/plan/flow/allocations", params: {
      plan_allocation: { account_id: @account.id, name: "Mystery", kind: "bill", mode: "specific" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.create_allocation.save_failed"), flash[:alert]
    assert_nil @family.plan_allocations.find_by(name: "Mystery")
  end

  test "update and destroy allocation rows" do
    row = PlanAllocation.create!(family: @family, account: @account, name: "Bills",
      kind: "bill", mode: "required", value_cents: 50_000)

    patch "/plan/flow/allocations/#{row.id}", params: {
      plan_allocation: { account_id: @account.id, name: "Bills", kind: "bill",
                         mode: "specific", value: "40.00" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.update_allocation.saved"), flash[:notice]
    assert_equal "specific", row.reload.mode
    assert_equal 4000, row.value_cents.to_i

    # Invalid edit flashes and keeps the previous state.
    patch "/plan/flow/allocations/#{row.id}", params: {
      plan_allocation: { account_id: @account.id, name: "Bills", kind: "bill", mode: "percent" }
    }
    assert_equal I18n.t("plan_flows.update_allocation.save_failed"), flash[:alert]
    assert_equal "specific", row.reload.mode

    delete "/plan/flow/allocations/#{row.id}"
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal I18n.t("plan_flows.destroy_allocation.saved"), flash[:notice]
    assert_nil @family.plan_allocations.find_by(id: row.id)
  end

  test "update account writes plan_role and the auto-transfer link" do
    savings = @family.accounts.create!(name: "Savings", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)

    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "savings_bucket",
                 auto_transfer_to_account_id: savings.id }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal "savings_bucket", @account.reload.plan_role
    assert_equal savings.id, @account.auto_transfer_to_account_id

    # Blank values clear both fields.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared", plan_role: "", auto_transfer_to_account_id: "" }
    }
    assert_nil @account.reload.plan_role
    assert_nil @account.auto_transfer_to_account_id
  end

  test "update account upserts the linked-income edges from the links param" do
    series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)
    savings = @family.accounts.create!(name: "Savings", owner: @user, currency: "USD",
      balance: 0, accountable: Depository.new)
    IncomeAccountAllocation.create!(family: @family, income_series: series,
      account: @account, mode: "percent", value: 0.5)
    IncomeAccountAllocation.create!(family: @family, income_series: series,
      account: savings, mode: "specific", value: 100)

    # Both incomes checked on @account: the percent edge is replaced by leftover.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared" },
      links: { series.id.to_s => { "enabled" => "1", "mode" => "leftover" } }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    edge = IncomeAccountAllocation.where(income_series: series, account: @account).first
    assert_equal "leftover", edge.mode
    assert_nil edge.value
    # The other account's edge is untouched.
    assert IncomeAccountAllocation.exists?(income_series: series, account: savings)

    # Unchecked: the edge is removed.
    patch "/plan/flow/accounts/#{@account.id}", params: {
      account: { plan_ownership: "shared" },
      links: { series.id.to_s => { "enabled" => "", "mode" => "leftover" } }
    }
    assert_not IncomeAccountAllocation.exists?(income_series: series, account: @account)
    assert IncomeAccountAllocation.exists?(income_series: series, account: savings)
  end

  test "update income writes the bank-link limit and flashes on an invalid one" do
    series = create_income_series(account: @account, name: "Bob Payroll", amount: 900)

    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: "", plan_max_account_links: "3" }
    }
    assert_redirected_to "/plan/flow?view=paycheck"
    assert_equal 3, series.reload.plan_max_account_links

    # 0 violates the >= 1 check: alert flash, value unchanged.
    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: "", plan_max_account_links: "0" }
    }
    assert_equal I18n.t("plan_flows.update_income.save_failed"), flash[:alert]
    assert_equal 3, series.reload.plan_max_account_links

    # Blank clears the limit.
    patch "/plan/flow/incomes/#{series.id}", params: {
      series: { plan_owner_user_id: "", plan_max_account_links: "" }
    }
    assert_nil series.reload.plan_max_account_links
  end
end
