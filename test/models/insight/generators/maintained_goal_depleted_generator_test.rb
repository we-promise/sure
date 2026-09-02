require "test_helper"

class Insight::Generators::MaintainedGoalDepletedGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "flags a reserve that has fallen below its level" do
    goal = reserve(name: "Precaution", balance: 4_000, target: 6_000)

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "maintained_goal_depleted", insight.insight_type
    assert_equal "high", insight.priority
    assert_equal goal.id, insight.metadata[:goal_id]
    assert_equal 2_000, insight.metadata[:missing]
  end

  test "says nothing about a reserve sitting at its level" do
    reserve(name: "Whole", balance: 6_000, target: 6_000)

    assert_empty generate
  end

  # A paused reserve is one the user shelved on purpose. `behind_pace?` excludes
  # paused goals for the same reason: nagging about a goal someone deliberately
  # put down is noise, not a signal.
  test "says nothing about a reserve the user paused" do
    reserve(name: "Shelved", balance: 1_000, target: 6_000).pause!

    assert_empty generate
  end

  test "ignores one-off goals, however short they are" do
    account = fresh_account(0)
    @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    assert_empty generate
  end

  # The dedup key rotates monthly: a reserve can sit short for weeks while the
  # user rebuilds it, and re-raising the same shortfall nightly would train them
  # to dismiss the feed.
  test "the dedup key carries the goal and the month" do
    goal = reserve(name: "Precaution", balance: 4_000, target: 6_000)

    assert_equal "maintained_goal_depleted:#{goal.id}:#{Date.current.strftime('%Y-%m')}",
                 generate.first.dedup_key
  end

  # A family running several drained reserves has one problem, not four.
  test "caps how many it raises, worst shortfall first" do
    reserve(name: "Small gap", balance: 5_000, target: 6_000)
    reserve(name: "Big gap", balance: 1_000, target: 9_000)
    reserve(name: "Middle gap", balance: 3_000, target: 6_000)

    insights = generate

    assert_equal 2, insights.size
    assert_equal [ 8_000, 3_000 ], insights.map { |i| i.metadata[:missing] }
  end

  private
    def generate
      Insight::Generators::MaintainedGoalDepletedGenerator.new(@family).generate
    end

    # A dedicated account each time: the fixtures already have goals claiming
    # `depository`, and a shared one would drag the pro-rata haircut into every
    # shortfall figure asserted here.
    def fresh_account(balance)
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "Pot #{SecureRandom.hex(4)}", currency: "USD", balance: balance
      )
    end

    def reserve(name:, balance:, target:)
      @family.goals.create!(name: name, target_amount: target, currency: "USD", kind: "maintained") do |g|
        g.goal_accounts.build(account: fresh_account(balance))
      end
    end
end
