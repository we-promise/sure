require "test_helper"

class Goal::WithdrawalDetectorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Trip Pot #{SecureRandom.hex(4)}", currency: "USD", balance: 5_000
    )
    @goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: @account, allocated_amount: 5_000)
    end
  end

  test "surfaces an outflow nothing has claimed" do
    entry = outflow(1_200)

    assert_equal [ entry.id ], detect.map(&:id)
  end

  # In Sure an inflow carries a NEGATIVE amount. Reading the sign the other way
  # round would offer to attribute the user's own deposits as spending.
  test "never surfaces an inflow" do
    outflow(-1_200)

    assert_empty detect
  end

  test "ignores an outflow below the threshold" do
    outflow(Goal::WithdrawalDetector::MIN_AMOUNT - 1)

    assert_empty detect
  end

  test "ignores an outflow the user excluded" do
    outflow(1_200).update!(excluded: true)

    assert_empty detect
  end

  test "ignores an outflow older than the window" do
    outflow(1_200, date: (Goal::WithdrawalDetector::LOOKBACK_DAYS + 1).days.ago.to_date)

    assert_empty detect
  end

  test "stops offering an outflow once it has been attributed" do
    entry = outflow(1_200)
    assert_equal [ entry.id ], detect.map(&:id)

    @goal.consume!(1_200, transaction: entry.entryable)

    assert_empty detect
  end

  # A reserve is drawn down and refilled, not spent. Asking the user to
  # attribute a withdrawal from one would invite them to erase the shortfall
  # the reserve exists to report.
  test "says nothing for a reserve" do
    reserve_account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Reserve Pot", currency: "USD", balance: 4_000
    )
    reserve = @family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: "USD", kind: "maintained"
    ) { |g| g.goal_accounts.build(account: reserve_account) }
    create_outflow(reserve_account, 1_200, Date.current)

    assert_empty Goal::WithdrawalDetector.new(reserve).unattributed_outflows
  end

  test "an outflow on an account this goal does not fund is not its business" do
    other = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Other Pot", currency: "USD", balance: 5_000
    )
    create_outflow(other, 1_200, Date.current)

    assert_empty detect
  end

  test "newest first, capped" do
    older = outflow(1_000, date: 10.days.ago.to_date)
    newest = outflow(2_000, date: 1.day.ago.to_date)
    middle = outflow(3_000, date: 5.days.ago.to_date)

    assert_equal [ newest.id, middle.id ], detect(limit: 2).map(&:id)
    assert_includes detect(limit: 3).map(&:id), older.id
  end

  # --- Review follow-ups ---

  # A released goal has handed its accounts back, so a later outflow on one of
  # them is not evidence about this goal. Offering it invites the user to write
  # spending into a history that is already closed.
  test "says nothing once the goal has been released" do
    entry = outflow(1_200)
    assert_equal [ entry.id ], detect.map(&:id)

    @goal.complete!

    assert_empty detect
  end

  test "says nothing for an archived goal" do
    outflow(1_200)
    @goal.archive!

    assert_empty detect
  end

  # A provisional charge can still be reversed, or replaced by its posted form.
  # Attributing one leaves the goal consumed for a transaction that no longer
  # exists, while the posted twin arrives unstamped and is offered all over.
  test "ignores an outflow the provider has not posted yet" do
    entry = outflow(1_200)
    entry.entryable.update!(extra: { "simplefin" => { "pending" => true } })

    assert_empty detect
  end

  test "still surfaces an outflow the provider has posted" do
    entry = outflow(1_200)
    entry.entryable.update!(extra: { "simplefin" => { "pending" => false } })

    assert_equal [ entry.id ], detect.map(&:id)
  end

  private
    def detect(limit: 3)
      Goal::WithdrawalDetector.new(@goal).unattributed_outflows(limit: limit)
    end

    def outflow(amount, date: Date.current)
      create_outflow(@account, amount, date)
    end

    def create_outflow(account, amount, date)
      account.entries.create!(
        name: "Spend #{SecureRandom.hex(3)}",
        date: date,
        amount: amount,
        currency: account.currency,
        entryable: Transaction.new
      )
    end
end
