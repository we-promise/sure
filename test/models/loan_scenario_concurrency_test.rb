require "test_helper"
require "concurrent"

# Gate G5. The five-scenario cap must hold under concurrent creation.
#
# A `position < 5` row check never bounded the row count -- five rows can all
# hold position 0 -- and counting rows in the model races: two requests both
# read four, both write, and the loan ends up with six. The cap is therefore an
# allocated slot with a unique (loan_id, slot) index, which the database
# enforces whatever the interleaving (finding F8).
#
# Real threads on real connections, so this needs real commits.
class LoanScenarioConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Slot Cap Race", currency: "USD")
    @account = Account.create!(
      family: @family, name: "Mortgage", currency: "USD", balance: 300_000,
      accountable: Loan.new(rate_type: "fixed", interest_rate: 5, term_months: 360)
    )
    @loan = @account.loan

    4.times { |i| LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Existing #{i}" }) }
    assert_equal 4, scenario_count, "setup must leave exactly one free slot"
  end

  teardown do
    LoanExtraRepayment.where(loan_scenario_id: LoanScenario.where(loan_id: @loan.id).select(:id)).delete_all
    LoanScenario.where(loan_id: @loan.id).delete_all
    @account.destroy
    @family.destroy
  end

  test "two simultaneous creates on the last free slot produce one success and one clean rejection" do
    latch = Concurrent::CountDownLatch.new(2)

    outcomes = 2.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          loan = Loan.find(@loan.id)
          # Both threads read the taken slots before either inserts, which is
          # the interleaving model-level counting cannot survive.
          latch.count_down
          latch.wait(5)

          LoanScenario.create_in_free_slot(loan: loan, attributes: { name: "Racer #{i}" })
        end
      end
    end.map(&:value)

    # Counted straight from the table, not through `@loan.loan_scenarios`: the
    # association on the outer object is cached and would not see rows another
    # connection committed, which reads as "the cap failed" when it did not.
    assert_equal 5, scenario_count,
      "the cap is five; a sixth row means the unique index did not hold"
    assert_equal 1, outcomes.count(&:persisted?), "exactly one writer must win"

    loser = outcomes.reject(&:persisted?).sole
    assert_predicate loser.errors, :any?,
      "the losing writer must be rejected cleanly, not raise or silently no-op"
    assert_empty loser.errors.full_messages.grep(/PG::|ActiveRecord::/),
      "the rejection must be a validation error, not a leaked database exception"
    assert_empty loser.errors.full_messages.grep(/[Tt]ranslation missing/),
      "the message reaches the user, so it must actually be translated"
    assert_equal [ I18n.t("activerecord.errors.models.loan_scenario.attributes.base.slot_cap_reached") ],
      loser.errors.full_messages
  end

  test "the sixth scenario is refused at the database layer, not only the model" do
    LoanScenario.create_in_free_slot(loan: @loan, attributes: { name: "Fifth" })
    assert_equal 5, scenario_count

    # Bypasses `create_in_free_slot` entirely and reuses an allocated slot, the
    # way a bug or a console would. The index must still refuse it.
    assert_raises ActiveRecord::RecordNotUnique do
      LoanScenario.create!(
        loan: @loan, name: "Sixth", currency: "USD", slot: 0,
        calculator_version: Loan::AmortizationSchedule::ALGORITHM_VERSION
      )
    end

    assert_equal 5, scenario_count
  end

  test "a slot outside 0..4 is refused by the check constraint" do
    assert_raises ActiveRecord::StatementInvalid do
      LoanScenario.new(
        loan: @loan, name: "Out of range", currency: "USD", slot: 9,
        calculator_version: Loan::AmortizationSchedule::ALGORITHM_VERSION
      ).save(validate: false)
    end
  end

  private

    # Counted on a connection of its own.
    #
    # Not `@loan.loan_scenarios.count` (the association on the outer object is
    # cached and reports a stale figure), and not a plain query on the test's
    # own connection either: rows the racing threads commit are not visible
    # from it, so counting there reports the cap failing when it held. Reading
    # from a fresh connection is what the racing writers themselves see.
    def scenario_count
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          LoanScenario.where(loan_id: @loan.id).count
        end
      end.value
    end
end
