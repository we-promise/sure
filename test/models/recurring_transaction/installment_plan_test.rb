require "test_helper"

class RecurringTransaction::InstallmentPlanTest < ActiveSupport::TestCase
  setup do
    travel_to Date.new(2026, 10, 22)
    @user = users(:family_admin)
    @family = @user.family
    @category = categories(:one)
    @interest_category = categories(:food_and_drink)
    # A card of its own, so the balance is the plan's business and nothing
    # else: the fixture card carries an opening balance.
    @card = @family.accounts.create!(
      name: "Plan Card",
      accountable: CreditCard.new,
      balance: 0,
      currency: "USD",
      owner: @user,
      status: "active"
    )
  end

  teardown do
    travel_back
  end

  test "a plan is a bills installment series that projects the instalments" do
    plan = build_plan

    assert plan.persisted?, plan.errors.full_messages.to_sentence
    assert_equal "installment", plan.bill_type
    assert_equal "after_count", plan.end_mode
    assert_equal 12, plan.end_after_count
    assert_equal @card, plan.account
    assert_equal @category, plan.category
  end

  test "the instalments are occurrences, not ledger entries" do
    purchase = create_purchase
    entries_before = @card.entries.count

    plan = build_plan(entry: purchase)

    assert_equal 12, plan.recurring_occurrences.count
    assert_equal Date.new(2026, 11, 22), plan.recurring_occurrences.minimum(:due_on)
    assert_equal Date.new(2027, 10, 22), plan.recurring_occurrences.maximum(:due_on)
    assert_equal entries_before, @card.entries.count, "the plan writes nothing into the ledger"
  end

  test "the monthly amount comes from the loan layer, not a second formula" do
    plan = build_plan

    schedule = Loan::AmortizationSchedule.new(
      principal: 1200,
      annual_rate: 12,
      term_months: 12,
      start_date: Date.new(2026, 10, 22),
      currency: "USD"
    )

    assert_equal schedule.periodic_payment.amount, plan.amount
    assert_equal schedule.total_interest.amount, plan.financed_total_interest.amount
    assert_equal schedule.total_paid.amount, plan.financed_schedule.total_paid.amount
  end

  test "the plan reports what each instalment costs and what is interest" do
    plan = build_plan

    first = plan.financed_installment(1)
    assert_equal 106.62, first[:amount].amount
    assert_equal 94.62, first[:principal].amount
    assert_equal 12.00, first[:interest].amount

    assert_equal 12, plan.financed_installments.size
    assert_equal Date.new(2026, 11, 22), plan.financed_installments.first[:date]
    assert_equal Date.new(2027, 10, 22), plan.financed_payoff_date
  end

  # The loan engine sizes the last payment so the balance lands on zero, so
  # the last occurrence expects a few cents less than the others.
  test "the last occurrence expects what the schedule says it costs" do
    plan = build_plan

    expected = plan.financed_schedule.payments.last.payment.amount

    assert_equal expected, plan.recurring_occurrences.order(:due_on).last.resolved_expected_amount
    assert_operator expected, :<, plan.amount
  end

  test "the purchase stops counting towards the budget and the balance" do
    purchase = create_purchase
    assert_equal 1200, card_balance
    assert_equal 1200, budget_spend(purchase.date.beginning_of_month, purchase.date.end_of_month, account: @card)

    plan = build_plan(entry: purchase)

    assert purchase.reload.excluded?
    assert_equal 0, card_balance, "the purchase left the card balance"
    assert_equal 0, budget_spend(purchase.date.beginning_of_month, purchase.date.end_of_month, account: @card)
    assert plan.persisted?
  end

  test "the budget reserves the instalments the plan has committed to" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)

    budget = @family.budgets.create!(
      start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2027, 10, 31),
      currency: "USD"
    )
    budget_category = budget.budget_categories.create!(
      category: @category,
      budgeted_spending: 400,
      currency: "USD"
    )

    assert_equal plan.financed_schedule.total_paid.amount, budget_category.bills_reserved.amount
  end

  test "the plan keeps the category that receives the interest" do
    plan = build_plan

    assert_equal @interest_category, plan.financed_interest_category
  end

  # The reserve is a forecast of cash, not money moved. It stays whole under
  # the purchase category; the split starts when the charge lands. Otherwise
  # the financing category would look spent before the card was charged.
  test "the budget splits principal and interest when the charge lands" do
    plan = build_plan
    budget = @family.budgets.create!(
      start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 30),
      currency: "USD"
    )
    principal_budget = budget.budget_categories.create!(
      category: @category,
      budgeted_spending: 400,
      currency: "USD"
    )
    interest_budget = budget.budget_categories.create!(
      category: @interest_category,
      budgeted_spending: 100,
      currency: "USD"
    )

    assert_equal 106.62, principal_budget.bills_reserved.amount.to_f
    assert_equal 0, interest_budget.bills_reserved.amount.to_f

    pay_instalment(plan)
    principal_budget = BudgetCategory.find(principal_budget.id)
    interest_budget = BudgetCategory.find(interest_budget.id)

    assert_equal 0, principal_budget.bills_reserved.amount.to_f
    assert_equal 94.62, principal_budget.actual_spending.to_f
    assert_equal 12.00, interest_budget.actual_spending.to_f
  end

  test "a plan charge splits into principal and interest" do
    plan = build_plan
    charge = pay_instalment(plan)

    assert charge.reload.split_parent?
    assert charge.excluded?

    principal, interest = charge.child_entries.includes(:entryable).sort_by { |child| -child.amount }

    assert_equal 94.62, principal.amount.to_f
    assert_equal @category.id, principal.entryable.category_id
    assert_equal "Laptop Store (principal)", principal.name

    assert_equal 12.00, interest.amount.to_f
    assert_equal @interest_category.id, interest.entryable.category_id
    assert_equal "Laptop Store (interest)", interest.name

    assert_equal 106.62, card_balance,
      "the split changes attribution, not the card balance"
  end

  test "a charge that differs from the estimate keeps the scheduled interest" do
    plan = build_plan
    occurrence = plan.recurring_occurrences.order(:due_on).first
    charge = @card.entries.create!(
      date: occurrence.due_on,
      name: "Laptop Store",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new(kind: "standard", category: @category)
    )

    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: charge)

    principal, interest = charge.reload.child_entries.sort_by { |child| -child.amount }

    assert_equal 88.00, principal.amount.to_f
    assert_equal 12.00, interest.amount.to_f
  end

  test "a partial payment stays whole" do
    plan = build_plan
    occurrence = plan.recurring_occurrences.order(:due_on).first
    charge = @card.entries.create!(
      date: occurrence.due_on,
      name: "Laptop Store",
      amount: 106.62,
      currency: "USD",
      entryable: Transaction.new(kind: "standard", category: @category)
    )

    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: charge, amount: 50)

    refute charge.reload.split_parent?
    assert_equal 106.62, card_balance
  end

  test "a plan without an interest category leaves the charge whole" do
    plan = build_plan(interest_category: nil)
    charge = pay_instalment(plan)

    refute charge.reload.split_parent?
    assert_equal 106.62, card_balance
  end

  test "unlinking the last payment from an ended plan releases the purchase" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    charge = pay_instalment(plan)
    plan.update!(status: "ended")
    assert purchase.reload.excluded?

    allocation = charge.reload.recurring_allocations.confirmed.sole
    occurrence = plan.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).unallocate!(allocation)

    assert_not purchase.reload.excluded?
  end

  test "unlinking a payment unsplits its charge" do
    plan = build_plan
    charge = pay_instalment(plan)
    occurrence = plan.recurring_occurrences.order(:due_on).first
    allocation = charge.reload.recurring_allocations.confirmed.sole

    assert charge.split_parent?

    RecurringTransaction::Allocator.new(occurrence).unallocate!(allocation)

    refute charge.reload.split_parent?
    refute charge.excluded?
    assert_equal 0, charge.child_entries.count
    assert_equal 106.62, card_balance
  end

  test "a failed split rolls back the payment" do
    plan = build_plan
    occurrence = plan.recurring_occurrences.order(:due_on).first
    charge = @card.entries.create!(
      date: occurrence.due_on, name: "Laptop Store",
      amount: occurrence.resolved_expected_amount, currency: "USD",
      entryable: Transaction.new(kind: "standard", category: @category)
    )

    RecurringTransaction::FinancedChargeSplitter
      .any_instance
      .stubs(:split!)
      .raises(ActiveRecord::RecordInvalid.new(charge))

    assert_raises(ActiveRecord::RecordInvalid) do
      RecurringTransaction::Allocator.new(occurrence).allocate!(entry: charge)
    end

    assert_empty charge.reload.recurring_allocations
    refute charge.reload.split_parent?
  end

  test "a failed unsplit keeps the payment linked" do
    plan = build_plan
    charge = pay_instalment(plan)
    occurrence = plan.recurring_occurrences.order(:due_on).first
    allocation = charge.reload.recurring_allocations.confirmed.sole

    Entry.any_instance.stubs(:unsplit!).raises(ActiveRecord::RecordInvalid.new(charge))

    assert_raises(ActiveRecord::RecordInvalid) do
      RecurringTransaction::Allocator.new(occurrence).unallocate!(allocation)
    end

    assert charge.reload.recurring_allocations.confirmed.exists?,
      "the payment stays linked when the charge cannot be unsplit"
    assert charge.reload.split_parent?
  end

  test "a bill cannot match the split children of a plan charge" do
    plan = build_plan
    charge = pay_instalment(plan)
    children = charge.reload.child_entries.to_a
    due = charge.date

    @family.recurring_transactions.create!(
      name: "Laptop Store (principal)",
      account: @card,
      amount: 94.62,
      currency: "USD",
      expected_day_of_month: due.day,
      anchor_date: due,
      last_occurrence_date: due,
      next_expected_date: due,
      status: "active",
      manual: true
    )

    RecurringTransaction::Matcher.new(@family).run!

    assert_empty RecurringAllocation.where(entry_id: children.map(&:id))
  end

  test "an interest category outside the family is refused" do
    plan = build_plan(
      interest_category: nil,
      interest_category_id: "00000000-0000-0000-0000-000000000000"
    )

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_invalid_interest_category")
  end

  test "a purchase on a synced account is refused" do
    purchase = create_purchase(account: accounts(:connected))

    plan = build_plan(entry: purchase)

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_purchase_not_manual")
    assert_not purchase.reload.excluded?, "the purchase is left alone"
  end

  test "a purchase that is not a plain expense is refused" do
    purchase = create_purchase(kind: "cc_payment")

    plan = build_plan(entry: purchase)

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_purchase_not_standard")
    assert_not purchase.reload.excluded?
  end

  test "a split child cannot become its own plan" do
    purchase = create_purchase
    child = purchase.split!([
      { name: "Part one", amount: 600, category_id: @category.id, excluded: false },
      { name: "Part two", amount: 600, category_id: @category.id, excluded: false }
    ]).first

    plan = build_plan(entry: child)

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_purchase_not_standard")
  end

  test "the first payment cannot fall before the purchase" do
    plan = build_plan(first_due_on: Date.new(2026, 10, 1))

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_invalid_first_due")
  end

  test "a purchase on an account the user cannot write to is refused" do
    purchase = create_purchase(account: accounts(:credit_card))

    plan = build_plan(entry: purchase, user: users(:family_member))

    assert_not plan.persisted?
    assert_not purchase.reload.excluded?
  end

  test "the same purchase cannot be planned twice" do
    purchase = create_purchase
    build_plan(entry: purchase)

    second = build_plan(entry: purchase)

    assert_not second.persisted?
    assert_includes second.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_purchase_already_planned")
  end

  test "releasing the plan hands the purchase back" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)

    assert plan.release_financed_purchase!

    assert_not purchase.reload.excluded?
    assert_equal 1200, card_balance
    assert_equal "ended", plan.reload.status
  end

  test "a plan-owned purchase cannot change financial fields" do
    purchase = create_purchase
    build_plan(entry: purchase)
    purchase.reload

    assert_not purchase.update(name: "Changed")
    assert_includes purchase.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.entry.attributes.base.installment_plan_locked")

    assert_not purchase.update(amount: 100)
    assert_not purchase.update(date: Date.new(2026, 10, 1))
    assert_not purchase.transaction.update(category: @interest_category)
    assert_includes purchase.transaction.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.transaction.attributes.base.installment_plan_locked")
  end

  test "a plan-owned purchase cannot be deleted" do
    purchase = create_purchase
    build_plan(entry: purchase)

    assert_not purchase.destroy
    assert purchase.persisted?
    assert_includes purchase.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.entry.attributes.base.installment_plan_locked")
  end

  test "pausing a plan keeps its purchase" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)

    plan.mark_inactive!

    assert purchase.reload.excluded?
    assert_not purchase.update(name: "Changed")
    assert_not purchase.destroy
    assert purchase.persisted?
  end

  test "resuming a plan restores the last schedule amount" do
    plan = build_plan
    last = plan.recurring_occurrences.order(:due_on).last
    assert_equal 106.60, last.resolved_expected_amount.to_f

    plan.mark_inactive!
    plan.mark_active!

    last = plan.recurring_occurrences.order(:due_on).last
    assert_equal Date.new(2027, 10, 22), last.due_on
    assert_equal 106.60, last.resolved_expected_amount.to_f
  end

  test "a stale uncharged plan releases its purchase" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    plan.update_columns(
      last_occurrence_date: 8.months.ago.to_date,
      next_expected_date: 7.months.ago.to_date
    )
    plan.recurring_occurrences.delete_all

    RecurringTransaction.cleanup_stale_for(@family)

    assert plan.reload.ended?
    assert_not purchase.reload.excluded?
  end

  test "a plan refuses a manual toggle that would count the purchase again" do
    purchase = create_purchase
    build_plan(entry: purchase)

    assert_not purchase.update(excluded: false)

    assert purchase.reload.excluded?
    assert_includes purchase.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.entry.attributes.excluded.cannot_unexclude_planned_purchase")
  end

  test "a charged plan still refuses the toggle after it ends" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    pay_instalment(plan)
    plan.update!(status: "ended")

    assert_not purchase.update(excluded: false)
    assert purchase.reload.excluded?
  end

  test "a released purchase can use the exclude toggle again" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    plan.release_financed_purchase!

    purchase.reload

    assert purchase.update(excluded: true)
    assert purchase.update(excluded: false)
  end

  test "rejecting the last suggestion releases an inactive plan's purchase" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    occurrence = plan.recurring_occurrences.order(:due_on).first
    charge = @card.entries.create!(
      date: occurrence.due_on, name: "Laptop Store",
      amount: occurrence.resolved_expected_amount, currency: "USD",
      entryable: Transaction.new(kind: "standard", category: @category)
    )
    allocation = RecurringTransaction::Allocator.new(occurrence).allocate_matched!(
      entry: charge, state: "suggested", confidence: 0.7, signals: {}
    )
    plan.mark_inactive!

    RecurringTransaction::Allocator.new(occurrence).reject_suggestion!(allocation)

    assert plan.reload.ended?
    assert_not purchase.reload.excluded?
  end

  test "a plan that is over gives the purchase back" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)

    plan.update!(status: "paused")

    assert purchase.reload.excluded?, "a paused plan still owns the purchase"

    plan.update!(status: "ended")

    assert_not purchase.reload.excluded?
    assert_equal 1200, card_balance
    assert_empty plan.recurring_occurrences.open_status
  end

  test "an ended plan does not undo a later manual exclusion" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    plan.release_financed_purchase!

    purchase.reload.update!(excluded: true)
    plan.update!(name: "Renamed plan")

    assert purchase.reload.excluded?

    plan.destroy!

    assert purchase.reload.excluded?
  end

  # Once money has moved, the charges are the record. Counting the purchase
  # as well would put both the purchase and its instalments in the budget.
  test "a plan that took a payment keeps the purchase out when it ends" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    pay_instalment(plan)

    plan.update!(status: "ended")

    assert purchase.reload.excluded?, "the charge replaced the purchase"
    assert_empty plan.recurring_occurrences.open_status
    assert_equal 106.62, card_balance
    assert_equal 106.62,
      budget_spend(purchase.date.beginning_of_month, purchase.date.next_month.end_of_month, account: @card)
  end

  test "deleting an uncharged plan returns the purchase" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)

    plan.destroy!

    assert_not purchase.reload.excluded?
    assert_equal 1200, card_balance
  end

  test "replacing the purchase category moves the plan with it" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    replacement = categories(:income)

    @category.replace_and_destroy!(replacement)

    assert_equal replacement, plan.reload.category
    assert_equal replacement, purchase.reload.entryable.category
  end

  test "the generic editor cannot rewrite a financed plan's cadence" do
    plan = build_plan
    plan.rules_rewritten = true

    assert_not plan.save
    assert_includes plan.errors.full_messages,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_terms_locked")
  end

  test "the generic editor cannot rewrite a financed plan's weekend adjustment" do
    plan = build_plan
    plan.weekend_adjust = "after"

    assert_not plan.save
    assert_includes plan.errors.full_messages,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_terms_locked")
  end

  test "a plan that took a payment cannot be deleted" do
    purchase = create_purchase
    plan = build_plan(entry: purchase)
    pay_instalment(plan)

    assert_not plan.destroy

    assert plan.persisted?, "the plan stays so the purchase keeps its owner"
    assert purchase.reload.excluded?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_has_payments")
  end

  test "term parsing is decimal and rejects prefixes" do
    terms = RecurringTransaction::FinancingTerms

    assert terms.valid_term?("08")
    assert_not terms.valid_term?("0x10")
  end

  test "a purchase too small to make a payment is refused" do
    plan = build_plan(entry: create_purchase(amount: 0.001), interest_rate: 0)

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_invalid_amount")
  end

  test "an interest rate outside the range is refused" do
    plan = build_plan(interest_rate: 250)

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_invalid_rate")
  end

  test "a term outside the range is refused" do
    plan = build_plan(term_months: 0)

    assert_not plan.persisted?
    assert_includes plan.errors.full_messages.to_sentence,
      I18n.t("activerecord.errors.models.recurring_transaction.installment_plan_invalid_term")
  end

  private
    def build_plan(entry: create_purchase, user: @user, interest_rate: 12, term_months: 12,
                   first_due_on: nil, interest_category: @interest_category,
                   interest_category_id: nil)
      interest_category_id ||= interest_category&.id

      RecurringTransaction::InstallmentPlan.new(
        family: @family,
        user: user,
        entry: entry,
        interest_rate: interest_rate,
        term_months: term_months,
        first_due_on: first_due_on,
        interest_category_id: interest_category_id
      ).call
    end

    def create_purchase(amount: 1200, date: Date.new(2026, 10, 22), account: @card, kind: "standard")
      account.entries.create!(
        date: date,
        name: "Laptop Store",
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(kind: kind, category: @category)
      )
    end

    def pay_instalment(plan, number: 1)
      occurrence = plan.recurring_occurrences.order(:due_on)[number - 1]
      charge = @card.entries.create!(
        date: occurrence.due_on,
        name: "Laptop Store",
        amount: occurrence.resolved_expected_amount,
        currency: "USD",
        entryable: Transaction.new(kind: "standard", category: @category)
      )
      RecurringTransaction::Allocator.new(occurrence).allocate!(entry: charge)
      charge
    end

    def card_balance
      Balance::ForwardCalculator.new(@card).calculate.max_by(&:date)&.balance.to_f
    end

    def budget_spend(from, to, account: nil)
      scope = @family.transactions
      scope = scope.joins(:entry).where(entries: { account_id: account.id }) if account

      IncomeStatement::Totals.new(
        @family,
        transactions_scope: scope,
        date_range: from..to
      ).call.sum { |row| row.total.to_f }
    end
end
