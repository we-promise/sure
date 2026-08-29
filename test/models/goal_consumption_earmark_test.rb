require "test_helper"

# A transaction that attests the spend clears the earmark ceiling; a bare
# amount does not.
class GoalConsumptionEarmarkTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a transaction bigger than what remains is attributable when it attests the spend" do
    account = fresh_account(5_000)
    goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account) # whole-account link
    end
    entry = spend(account, 3_800, 5.days.ago)
    account.update!(balance: 1_200) # the spend already happened

    goal.consume!(3_800, transaction: entry.entryable)

    assert_equal BigDecimal("3800"), goal.reload.consumed_amount
  end

  # Without a transaction there is nothing attesting the money is already
  # gone, so the earmark ceiling still applies.
  test "a bare amount bigger than what remains is still refused" do
    account = fresh_account(5_000)
    goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    account.update!(balance: 1_200)

    assert_raises(Goal::ConsumptionRefused) { goal.consume!(3_800) }
  end

  # The target is still the real ceiling either way.
  test "a transaction bigger than the target is still refused" do
    account = fresh_account(5_000)
    goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    entry = spend(account, 6_000, 5.days.ago)
    account.update!(balance: -1_000)

    assert_raises(Goal::ConsumptionRefused) { goal.consume!(6_000, transaction: entry.entryable) }
  end

  private
    def fresh_account(balance)
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "Pot #{SecureRandom.hex(4)}", currency: "USD", balance: balance
      )
    end

    def spend(account, amount, date)
      account.entries.create!(
        name: "Spend #{SecureRandom.hex(3)}", date: date, amount: amount,
        currency: account.currency, entryable: Transaction.new
      )
    end
end
