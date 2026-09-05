require "test_helper"

class DepositoryTest < ActiveSupport::TestCase
  setup do
    @depository = accounts(:depository).depository
  end

  test "reports no overdraft terms when none were entered" do
    assert_not @depository.overdraft_terms?
    assert_equal 0, @depository.overdraft_floor
  end

  test "the overdraft floor is the negative of the stored limit" do
    @depository.update!(overdraft_limit: 400)

    assert @depository.overdraft_terms?
    assert_equal(-400, @depository.overdraft_floor)
  end

  # An agios rate on its own is a recorded term. Reading only the limit and the
  # fee amount dropped it from the assistant payload entirely.
  test "recognizes an overdraft interest rate on its own as recorded terms" do
    @depository.update!(overdraft_interest_rate: 13.9)

    assert @depository.overdraft_terms?
  end

  test "recognizes the fee threshold and caps on their own as recorded terms" do
    @depository.update!(intervention_fee_threshold: 20)
    assert @depository.overdraft_terms?

    @depository.update!(intervention_fee_threshold: nil, intervention_fee_monthly_cap: 80)
    assert @depository.overdraft_terms?

    @depository.update!(intervention_fee_monthly_cap: nil, intervention_fee_monthly_count_cap: 5)
    assert @depository.overdraft_terms?
  end

  test "returns nil rather than zero when the fee terms are unknown" do
    assert_nil @depository.intervention_fee_for(50),
               "unknown terms must be distinguishable from a zero fee"
  end

  test "charges the fee only above the threshold" do
    @depository.update!(intervention_fee_amount: 8, intervention_fee_threshold: 20)

    assert_equal 0, @depository.intervention_fee_for(15)
    assert_equal 0, @depository.intervention_fee_for(20), "the threshold itself is not above it"
    assert_equal 8, @depository.intervention_fee_for(20.01)
    assert_equal 8, @depository.intervention_fee_for(120)
  end

  test "treats a missing threshold as charging on every payment" do
    @depository.update!(intervention_fee_amount: 8, intervention_fee_threshold: nil)

    assert_equal 8, @depository.intervention_fee_for(1)
  end

  test "applies no cap when the bank sets none" do
    @depository.update!(intervention_fee_amount: 8)

    assert_equal 40, @depository.capped_monthly_fees([ 8, 8, 8, 8, 8 ])
  end

  test "caps the monthly fees by amount" do
    @depository.update!(intervention_fee_amount: 8, intervention_fee_monthly_cap: 24)

    assert_equal 24, @depository.capped_monthly_fees([ 8, 8, 8, 8, 8 ])
  end

  test "caps the monthly fees by count" do
    @depository.update!(intervention_fee_amount: 8, intervention_fee_monthly_count_cap: 3)

    assert_equal 24, @depository.capped_monthly_fees([ 8, 8, 8, 8, 8 ])
  end

  test "applies whichever cap binds first when the bank sets both" do
    @depository.update!(
      intervention_fee_amount: 8,
      intervention_fee_monthly_count_cap: 4,
      intervention_fee_monthly_cap: 20
    )

    assert_equal 20, @depository.capped_monthly_fees([ 8, 8, 8, 8, 8 ]),
                 "the count cap allows 32, the amount cap binds at 20"
  end

  test "rejects a negative overdraft limit at the database level" do
    assert_raises(ActiveRecord::StatementInvalid) do
      @depository.update!(overdraft_limit: -100)
    end
  end
end
