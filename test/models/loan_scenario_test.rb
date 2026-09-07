require "test_helper"

class LoanScenarioTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Scenario Mortgage", balance: 300_000, currency: "USD",
      accountable: Loan.new(rate_type: "fixed", interest_rate: 6, term_months: 360,
        initial_balance: 300_000, start_date: Date.current - 12.months)
    )
    @loan = @account.loan
  end

  test "scenarios fill the lowest free slot and stop at five" do
    slots = 5.times.map { |i| LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "S#{i}" }).slot }

    assert_equal [ 0, 1, 2, 3, 4 ], slots

    sixth = LoanScenario.create_in_free_slot(loan: @loan.reload, attributes: { name: "Sixth" })

    assert_not sixth.persisted?
    assert_equal [ I18n.t("activerecord.errors.models.loan_scenario.attributes.base.slot_cap_reached") ],
      sixth.errors.full_messages
    assert_equal 5, @loan.loan_scenarios.count
  end

  test "deleting a scenario frees its slot for reuse" do
    5.times { |i| LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "S#{i}" }) }
    @loan.loan_scenarios.find_by(slot: 2).destroy!

    replacement = LoanScenario.create_in_free_slot(loan: @loan.reload, attributes: { name: "Replacement" })

    assert_predicate replacement, :persisted?
    assert_equal 2, replacement.slot, "the freed slot is the lowest available and must be reused"
  end

  # Accounts are shared per user through `account_shares`, so two housemates
  # can both see one loan. A unique (loan_id, name) index would turn a cosmetic
  # collision between them into an error, which is why there isn't one.
  test "two people can both name a scenario Aggressive on the same loan" do
    first = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Aggressive", created_by_user: users(:family_admin) })
    second = LoanScenario.create_in_free_slot(loan: @loan.reload, attributes: { name: "Aggressive", created_by_user: users(:family_member) })

    assert_predicate first, :persisted?
    assert_predicate second, :persisted?
    assert_not_equal first.slot, second.slot
    assert_not_equal first.created_by_user_id, second.created_by_user_id,
      "attribution distinguishes them; the name does not have to"
  end

  test "deleting a loan cascades its scenarios and their repayments" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Doomed" })
    scenario.extra_repayments.create!(kind: "one_off", amount: 500, occurs_on: Date.current + 1.month)

    assert_difference -> { LoanScenario.count } => -1, -> { LoanExtraRepayment.count } => -1 do
      @account.destroy!
    end
  end

  test "a scenario records which engine produced its figures" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Versioned" })

    assert_equal Loan::AmortizationSchedule::ALGORITHM_VERSION, scenario.calculator_version
    assert_equal @account.currency, scenario.currency
  end

  # Scenarios are LIVE ESTIMATES, not snapshots: the result is deliberately not
  # persisted, so moving the loan's balance must move the projection.
  test "a scenario recomputes against the loan's current balance" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Live" })
    scenario.extra_repayments.create!(kind: "recurring", amount: 500, frequency: "monthly",
      interval: 1, starts_on: Date.current + 1.month)

    before = @loan.payoff_projection_for_scenario(scenario.reload).total_interest
    @account.update!(balance: 150_000)
    after = @loan.reload.payoff_projection_for_scenario(scenario).total_interest

    assert_operator after.amount, :<, before.amount,
      "halving the balance must change the estimate; a persisted result would not move"
  end

  test "an extra repayment larger than the balance cannot drive it negative" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Overpay" })
    scenario.extra_repayments.create!(kind: "one_off", amount: 10_000_000, occurs_on: Date.current + 1.month)

    projection = @loan.payoff_projection_for_scenario(scenario.reload)

    # `payments` is [] when the projection is not applicable, and `all?` on an
    # empty array is true -- so without this the assertion below passes without
    # exercising the cap at all (cubic, #83).
    assert_not_empty projection.payments, "an inapplicable projection proves nothing here"
    assert projection.payments.all? { |payment| payment[:ending_balance] >= 0 },
      "an overpayment is capped at the balance; the loan cannot go negative"
  end

  test "a repayment must match its kind" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Coherence" })

    assert_not scenario.extra_repayments.build(kind: "one_off", amount: 100, frequency: "weekly").valid?
    assert_not scenario.extra_repayments.build(kind: "recurring", amount: 100, occurs_on: Date.current).valid?
    assert_not scenario.extra_repayments.build(kind: "recurring", amount: 100, frequency: "monthly",
      starts_on: Date.current, ends_on: Date.current - 1.day).valid?
  end

  test "a scenario's currency must match its loan" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Wrong currency", currency: "EUR" })

    assert_not scenario.persisted?
    assert_includes scenario.errors.attribute_names, :currency
  end

  # Losing a slot race is not the same as the cap being reached. With three
  # scenarios and two concurrent creates, both pick the same lowest free slot;
  # rejecting the loser would report "five already" over an almost-empty loan.
  test "a slot collision below the cap retries instead of reporting the cap" do
    2.times { |i| LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "S#{i}" }) }

    # Simulate the race: the first save collides, the retry must find slot 3.
    collided = false
    LoanScenario.any_instance.stubs(:save).with do
      next true if collided
      collided = true
      raise ActiveRecord::RecordNotUnique, "duplicate key"
    end.returns(true)

    scenario = LoanScenario.create_in_free_slot(loan: @loan.reload, attributes: { name: "Racer" })

    assert_empty scenario.errors.full_messages,
      "a collision with free slots remaining must retry, not report the cap"
  end

  test "record_calculation! stamps when and by which engine" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Stamped" })
    assert_nil scenario.last_calculated_at

    scenario.record_calculation!

    assert_not_nil scenario.reload.last_calculated_at
    assert_equal Loan::AmortizationSchedule::ALGORITHM_VERSION, scenario.calculator_version
  end

  test "a recurring repayment without a start date is refused at both layers" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Anchorless" })

    repayment = scenario.extra_repayments.build(kind: "recurring", amount: 100, frequency: "quarterly")
    assert_not repayment.valid?, "without a start date the recurrence has no stable anchor"

    assert_raises ActiveRecord::StatementInvalid do
      repayment.save(validate: false)
    end
  end

  test "a non-positive interval is refused at the database layer" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Bad interval" })

    assert_raises ActiveRecord::StatementInvalid do
      scenario.extra_repayments.build(
        kind: "recurring", amount: 100, frequency: "monthly", interval: 0, starts_on: Date.current
      ).save(validate: false)
    end
  end

  test "reversed date bounds are refused at the database layer" do
    scenario = LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Reversed" })

    assert_raises ActiveRecord::StatementInvalid do
      scenario.extra_repayments.build(
        kind: "recurring", amount: 100, frequency: "monthly",
        starts_on: Date.current, ends_on: Date.current - 1.day
      ).save(validate: false)
    end
  end
end
