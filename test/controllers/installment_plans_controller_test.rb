require "test_helper"

class InstallmentPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @card = @family.accounts.create!(
      name: "Plan Card",
      accountable: CreditCard.new,
      balance: 0,
      currency: "USD",
      owner: @user,
      status: "active"
    )
    @purchase = create_purchase
    @interest_category = categories(:food_and_drink)
    ensure_tailwind_build
  end

  test "the transaction offers the plan next to the recurring actions" do
    get transaction_url(@purchase), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match I18n.t("transactions.show.installment_plan_title"), response.body
    assert_select "a[href=?]", new_transaction_installment_plan_path(@purchase)
  end

  test "the action stays hidden without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get transaction_url(@purchase), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_no_match I18n.t("transactions.show.installment_plan_title"), response.body
  end

  test "the dialog collects the issuer terms" do
    get new_transaction_installment_plan_url(@purchase), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "input[name=?]", "installment_plan[interest_rate]"
    assert_select "input[name=?]", "installment_plan[term_months]"
    assert_select "input[name=?]", "installment_plan[interest_category_id]"
    assert_select "input[name=?]", "installment_plan[first_due_on]"
    assert_match @purchase.name, response.body
  end

  test "creating the plan hands the purchase over" do
    assert_difference -> { @family.recurring_transactions.count }, 1 do
      post transaction_installment_plan_url(@purchase), params: {
        installment_plan: {
          interest_rate: 12,
          term_months: 12,
          first_due_on: Date.new(2026, 11, 22),
          interest_category_id: @interest_category.id
        }
      }
    end

    plan = @family.recurring_transactions.order(:created_at).last

    assert_redirected_to bill_path(plan)
    assert_equal "installment", plan.bill_type
    assert_equal 12, plan.end_after_count
    assert_equal 1200, plan.financed_principal_amount
    assert_equal @interest_category, plan.financed_interest_category
    assert_equal 12, plan.recurring_occurrences.count
    assert @purchase.reload.excluded?
  end

  test "the plan page shows the interest and principal split" do
    plan = build_plan(interest_category_id: @interest_category.id)
    occurrence = plan.recurring_occurrences.order(:due_on).first
    charge = @card.entries.create!(
      date: occurrence.due_on,
      name: @purchase.name,
      amount: occurrence.resolved_expected_amount,
      currency: "USD",
      entryable: Transaction.new(kind: "standard", category: categories(:one))
    )
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: charge)

    get bill_url(plan, display: "drawer"), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match "total interest", response.body
    assert_match "principal", response.body
  end

  test "the plan detail lists each installment split" do
    plan = build_plan(interest_category_id: @interest_category.id)

    get bill_url(plan, display: "history"),
        headers: { "Turbo-Frame" => ActionView::RecordIdentifier.dom_id(plan, :history) }

    assert_response :success
    assert_match I18n.t("bills.detail.financing"), response.body
    assert_match "principal", response.body
    assert_match "interest", response.body
  end

  test "the plan drawer opens the current terms" do
    plan = build_plan(interest_category_id: @interest_category.id)

    get edit_bill_installment_plan_url(plan)

    assert_response :success
    assert_select "form[action=?]", bill_installment_plan_path(plan)
    assert_select "input[name=?][value=?]", "installment_plan[term_months]", "12"
    assert_match I18n.t("installment_plans.edit_title"), response.body
    assert_match "106.62", response.body
  end

  test "the bill drawer offers plan term editing before a charge" do
    plan = build_plan

    get bill_url(plan, display: "drawer"), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_match I18n.t("bills.show.edit_plan"), response.body
  end

  test "the plan terms can be edited before the first charge" do
    plan = build_plan(interest_category_id: @interest_category.id)

    patch bill_installment_plan_url(plan), params: {
      installment_plan: {
        interest_rate: 0,
        term_months: 6,
        first_due_on: Date.new(2026, 12, 22),
        interest_category_id: @interest_category.id
      }
    }

    assert_redirected_to bill_path(plan)
    plan.reload

    assert_equal 6, plan.end_after_count
    assert_equal Date.new(2026, 12, 22), plan.anchor_date
    assert_equal 6, plan.recurring_occurrences.count
    assert_equal 200, plan.amount.to_f
    assert_equal [ 200 ], plan.recurring_occurrences.distinct.pluck(:expected_amount).map(&:to_f)
    assert_equal 0, plan.financed_total_interest.to_f
    assert @purchase.reload.excluded?
  end

  test "plan terms are refused after a payment is matched" do
    plan = build_plan
    occurrence = plan.recurring_occurrences.order(:due_on).first
    charge = @card.entries.create!(
      date: occurrence.due_on,
      name: @purchase.name,
      amount: occurrence.resolved_expected_amount,
      currency: "USD",
      entryable: Transaction.new(kind: "standard", category: categories(:one))
    )
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: charge)

    patch bill_installment_plan_url(plan), params: {
      installment_plan: { interest_rate: 0, term_months: 6, first_due_on: Date.new(2026, 12, 22) }
    }

    assert_redirected_to bill_path(plan)
    assert_equal I18n.t("installment_plans.terms_locked"), flash[:alert]
    assert_equal 12, plan.reload.end_after_count

    get bill_url(plan, display: "drawer"), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_no_match I18n.t("bills.show.edit_plan"), response.body
  end

  test "the dialog previews the loan engine's payment" do
    get preview_transaction_installment_plan_url(@purchase), params: {
      installment_plan: {
        interest_rate: 12,
        term_months: 12,
        first_due_on: Date.new(2026, 11, 22)
      }
    }

    assert_response :success
    assert_match "106.62", response.body
    assert_match "79.42", response.body
    assert_match "12 payments", response.body
  end

  test "the generic bill edit cannot rewrite plan terms" do
    plan = build_plan

    patch recurring_transaction_url(plan), params: {
      recurring_transaction: { name: "Renamed plan", amount: 10 }
    }

    assert_response :unprocessable_entity
    plan.reload

    assert_equal "Laptop Store", plan.name
    assert_equal 106.62, plan.amount.to_f
  end

  test "the generic bill edit still changes the name" do
    plan = build_plan

    patch recurring_transaction_url(plan), params: {
      recurring_transaction: { name: "Renamed plan", notes: "Kept" }
    }

    assert_redirected_to recurring_transactions_url
    plan.reload
    assert_equal "Renamed plan", plan.name
    assert_equal "Kept", plan.notes
    assert_equal 106.62, plan.amount.to_f
  end

  test "the generic bill form disables plan terms" do
    plan = build_plan

    get edit_recurring_transaction_url(plan), headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "fieldset[disabled]"
    assert_select "input[name=?][disabled]", "recurring_transaction[amount]"
    assert_select "input[name=?][disabled]", "recurring_transaction[account_name]"
    assert_match "come from its loan terms", response.body
  end

  test "the exclude toggle disappears while a plan owns the purchase" do
    build_plan

    get transaction_url(@purchase), headers: { "Turbo-Frame" => "drawer" }

    assert_response :success
    assert_select "input[name=?]", "entry[excluded]", count: 0
    assert_no_match I18n.t("transactions.show.open_matcher"), response.body
    assert_no_match I18n.t("transactions.show.create_bill"), response.body
  end

  test "a stale drawer cannot un-exclude a plan-owned purchase" do
    build_plan

    patch transaction_url(@purchase), params: { entry: { excluded: "0" } }

    assert_response :unprocessable_entity
    assert @purchase.reload.excluded?
  end

  test "an invalid rate reopens the dialog with the reason" do
    post transaction_installment_plan_url(@purchase), params: {
      installment_plan: { interest_rate: 250, term_months: 12 }
    }

    assert_response :unprocessable_entity
    assert_match I18n.t("installment_plans.new.errors_title"), response.body
    assert_match "between 0 and 100", response.body
    assert_not @purchase.reload.excluded?
  end

  test "a synced purchase is refused" do
    linked = accounts(:connected).entries.create!(
      date: Date.current,
      name: "Linked Laptop",
      amount: 1200,
      currency: "USD",
      entryable: Transaction.new(kind: "standard", category: categories(:one))
    )

    post transaction_installment_plan_url(linked), params: {
      installment_plan: { interest_rate: 12, term_months: 12 }
    }

    assert_response :unprocessable_entity
    assert_match I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_purchase_not_manual"),
      response.body
    assert_not linked.reload.excluded?
  end

  test "a purchase that already has a plan is refused" do
    RecurringTransaction::InstallmentPlan.new(
      family: @family,
      user: @user,
      entry: @purchase,
      interest_rate: 12,
      term_months: 12
    ).call

    get new_transaction_installment_plan_url(@purchase)

    assert_redirected_to transaction_path(@purchase)
    assert_equal I18n.t("installment_plans.not_available"), flash[:alert]
  end

  test "users without preview access cannot open the dialog" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get new_transaction_installment_plan_url(@purchase)

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "a family with Bills disabled cannot open the dialog" do
    @family.update!(recurring_transactions_disabled: true)

    get new_transaction_installment_plan_url(@purchase)

    assert_redirected_to root_path
  end

  private
    def build_plan(interest_category_id: nil)
      RecurringTransaction::InstallmentPlan.new(
        family: @family,
        user: @user,
        entry: @purchase,
        interest_rate: 12,
        term_months: 12,
        interest_category_id: interest_category_id
      ).call
    end

    def create_purchase(account: @card, kind: "standard")
      account.entries.create!(
        date: Date.new(2026, 10, 22),
        name: "Laptop Store",
        amount: 1200,
        currency: "USD",
        entryable: Transaction.new(kind: kind, category: categories(:one))
      )
    end
end
