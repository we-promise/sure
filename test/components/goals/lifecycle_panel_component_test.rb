require "test_helper"

# The panel choice was five predicates deep in ERB where the ordering between
# them mattered and nothing said so. These pin the order, not the markup.
class Goals::LifecyclePanelComponentTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "an archived or paused goal gets the inactive panel whatever its progress" do
    goal = funded_goal
    goal.archive!
    assert_equal :inactive, panel_for(goal)

    other = funded_goal(name: "Paused")
    other.pause!
    assert_equal :inactive, panel_for(other)
  end

  test "a reserve at its floor celebrates rather than reporting a shortfall" do
    assert_equal :celebration, panel_for(funded_goal(kind: "maintained"))
  end

  # A brand-new reserve sits at zero balance and zero pace, which is also what
  # the generic "make your first transfer" card tests for. It must not win:
  # what the reserve needs is how far below its floor it is.
  test "an empty reserve reports its shortfall rather than looking untouched" do
    goal = @family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: @family.currency, kind: "maintained"
    ) { |g| g.goal_accounts.build(account: pot(balance: 0), allocated_amount: 0) }

    assert_equal :reserve_shortfall, panel_for(goal)
  end

  test "a one-off goal with nothing in it yet is asked for its first transfer" do
    goal = @family.goals.create!(
      name: "Trip", target_amount: 5_000, currency: @family.currency
    ) { |g| g.goal_accounts.build(account: pot(balance: 0), allocated_amount: 0) }

    assert_equal :empty, panel_for(goal)
  end

  # A reserve is never offered closing: releasing the money would undo the
  # thing it exists for.
  test "a funded reserve is offered no closing action" do
    assert_equal :none, component_for(funded_goal(kind: "maintained")).celebration_action
  end

  # Closing releases the earmark; archiving does not. A goal merely at 100% is
  # still holding its money, so it gets the gesture that lets go of it.
  test "a goal at its target is offered closing, not archiving" do
    assert_equal :close, component_for(funded_goal).celebration_action
  end

  private
    def pot(balance:, name: "Pot #{SecureRandom.hex(3)}")
      Account.create!(family: @family, accountable: Depository.new, name: name,
                      currency: @family.currency, balance: balance)
    end

    def funded_goal(name: "Trip", kind: "one_off")
      @family.goals.create!(
        name: name, target_amount: 1_000, currency: @family.currency, kind: kind
      ) { |g| g.goal_accounts.build(account: pot(balance: 1_000), allocated_amount: 1_000) }
    end

    def component_for(goal)
      Goals::LifecyclePanelComponent.new(goal: goal)
    end

    def panel_for(goal)
      component_for(goal).panel
    end
end
