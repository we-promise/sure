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

    # Simulate the race properly. The old version stubbed `save` to return true
    # without persisting, so the retry was never observed to LAND anywhere --
    # `errors` was empty simply because nothing had happened. It passed whether
    # or not the retry worked (CodeRabbit, #83).
    #
    # Now a competing row really takes slot 2, the first save really raises, and
    # the retry delegates to the real `save`, so the assertion is on where the
    # scenario actually ended up.
    @loan.loan_scenarios.create!(name: "Competitor", slot: 2, currency: @loan.account.currency,
      calculator_version: Loan::AmortizationSchedule::ALGORITHM_VERSION)

    original_save = LoanScenario.instance_method(:save)
    collided = false
    LoanScenario.define_method(:save) do |*args|
      unless collided
        collided = true
        raise ActiveRecord::RecordNotUnique, "duplicate key"
      end
      original_save.bind(self).call(*args)
    end

    begin
      scenario = LoanScenario.create_in_free_slot(loan: @loan.reload, attributes: { name: "Racer" })
    ensure
      LoanScenario.define_method(:save, original_save)
    end

    assert_empty scenario.errors.full_messages,
      "a collision with free slots remaining must retry, not report the cap"
    assert_equal 3, scenario.slot,
      "the retry must land in the next free slot, not re-report the collided one"
  end

  # CodeRabbit, #83. `unamortizable_payment?` asks whether the CONTRACTED
  # repayment covers the first period's interest. A scenario's extra repayments
  # are not in that comparison, so a lump sum big enough to fix the shortfall
  # was rejected before it could be applied and the scenario showed nothing --
  # the same shape as the gate bug fixed on #79.
  test "a lump sum that fixes an interest shortfall is not rejected before it applies" do
    loan = under_serviced_loan
    scenario = LoanScenario.create_in_free_slot(loan: loan, attributes: { name: "Lump" })
    scenario.extra_repayments.create!(kind: "one_off", amount: 350_000, occurs_on: Date.current)

    projection = loan.payoff_projection_for_scenario(scenario.reload)

    assert projection.send(:unamortizable_payment?),
      "the fixture must actually trip the guard, or this test proves nothing"
    assert projection.applicable?
    assert projection.payments.any?,
      "the repayment clears most of the balance; the scenario must produce a projection"
  end

  # CodeRabbit, #83. Both columns were stored and validated but never read, so a
  # scenario carrying either produced a projection identical to the baseline.
  test "a rate override changes the projection" do
    loan = seasoned_loan
    baseline = loan.payoff_projection_for_scenario(
      LoanScenario.create_in_free_slot(loan: loan, attributes: { name: "Plain" }).reload
    )
    overridden = loan.payoff_projection_for_scenario(
      LoanScenario.create_in_free_slot(loan: loan, attributes: { name: "Cheap", rate_override: 2.0 }).reload
    )

    assert_operator overridden.total_interest.amount, :<, baseline.total_interest.amount,
      "pinning the rate to 2% must cost less interest than the loan's own 6.18%"
  end

  test "an assumed offset balance changes the projection" do
    loan = seasoned_loan
    baseline = loan.payoff_projection_for_scenario(
      LoanScenario.create_in_free_slot(loan: loan, attributes: { name: "No offset" }).reload
    )
    offset = loan.payoff_projection_for_scenario(
      LoanScenario.create_in_free_slot(
        loan: loan, attributes: { name: "Offset", assumed_offset_balance: 150_000 }
      ).reload
    )

    assert_operator offset.total_interest.amount, :<, baseline.total_interest.amount,
      "an assumed $150,000 offset must reduce the interest charged"
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
  private

    # Contracted at 1%, then a rise to 12% already in effect: the contracted
    # repayment no longer covers a single period's interest.
    def under_serviced_loan
      loan = families(:dylan_family).accounts.create!(
        name: "Under-serviced Scenario Loan", balance: 400_762.12, currency: "USD",
        accountable: Loan.new(rate_type: "variable", interest_rate: 1.0, term_months: 360,
          initial_balance: 400_762.12, start_date: Date.current - 83.months)
      ).loan
      loan.add_variable_rate_change(Date.current - 1.month, 12.0)
      loan.reload
    end

    def seasoned_loan
      families(:dylan_family).accounts.create!(
        name: "Seasoned Scenario Loan #{SecureRandom.hex(4)}", balance: 400_762.12, currency: "USD",
        accountable: Loan.new(rate_type: "variable", interest_rate: 6.18, term_months: 360,
          initial_balance: 400_762.12, start_date: Date.current - 83.months)
      ).loan.reload
    end
end
