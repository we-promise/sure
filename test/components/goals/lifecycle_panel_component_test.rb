require "test_helper"

# The panel choice was five predicates deep in ERB where the ordering between
# them mattered and nothing said so. These pin the order, not the markup.
class Goals::LifecyclePanelComponentTest < ViewComponent::TestCase
  setup do
    @family = families(:dylan_family)
    # The panel scopes what it offers to the reader's accessible accounts, so
    # these need a reader — without one the offer is correctly withheld and
    # every assertion about it would be measuring the wrong thing.
    Current.session = sessions(:one)
  end

  teardown { Current.session = nil }

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

  # Adding money had a button on this page; using it had none. And the moment
  # it was most wanted — target reached, trip taken — the page offered only
  # "Close this goal", which does something else and whose own hint tells you
  # to have spent the money first.
  test "a goal still holding money offers to record a spend" do
    assert component_for(funded_goal).offer_recording_a_spend?
  end

  # Beside closing, never instead of it: a goal is often closed without
  # anything being recorded, and this must not read as a step to clear first.
  test "the closing action is unaffected by the offer" do
    goal = funded_goal

    assert_equal :close, component_for(goal).celebration_action
    assert component_for(goal).offer_recording_a_spend?
  end

  # A reserve refuses consumption outright, so offering it would be offering
  # something the model then declines.
  test "a reserve is never offered a spend" do
    assert_not component_for(funded_goal(kind: "maintained")).offer_recording_a_spend?
  end

  # Nothing left to spend, and nothing to spend it from once closed.
  test "a closed goal is not offered a spend" do
    goal = funded_goal
    goal.complete!

    assert_not component_for(goal.reload).offer_recording_a_spend?
  end

  test "a goal holding nothing is not offered a spend" do
    goal = @family.goals.create!(
      name: "Empty", target_amount: 1_000, currency: @family.currency
    ) { |g| g.goal_accounts.build(account: pot(balance: 0), allocated_amount: 0) }

    assert_not component_for(goal).offer_recording_a_spend?
  end

  # `current_balance` counts every linked account, private ones included. The
  # offer used to ride on that, so a reader backed only by somebody else's
  # private account was sent to a dialog with nothing to pick and a refusal on
  # submit.
  test "money the reader cannot reach does not earn the offer" do
    private_account = Account.create!(
      family: @family, owner: users(:family_member), accountable: Depository.new,
      name: "Member Private", currency: @family.currency, balance: 5_000
    )
    private_account.account_shares.destroy_all
    goal = @family.goals.create!(
      name: "Hidden", target_amount: 5_000, currency: @family.currency
    ) { |g| g.goal_accounts.build(account: private_account, allocated_amount: 5_000) }

    assert goal.current_balance.to_d.positive?, "the goal is backed, just not for this reader"
    assert_not component_for(goal).offer_recording_a_spend?
  end

  # A reserve gets neither action, so the row must not render at all — an
  # empty flex div still carries its top margin, and would open a gap under
  # copy that says there is nothing to do.
  test "a reserve renders no action row" do
    goal = funded_goal(kind: "maintained")

    # Rendered, not merely asked: the predicates could both stay false while
    # the template emitted the row anyway, which is the gap this guards.
    render_inline(component_for(goal))

    assert_no_selector "#goal-celebration-actions"
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

    # The same list the controller hands the panel and the overflow menu: the
    # goal's accounts this reader can actually reach.
    def component_for(goal)
      visible = Current.user.accessible_accounts.where(id: goal.linked_accounts.map(&:id)).pluck(:id)
      Goals::LifecyclePanelComponent.new(goal: goal, viewer_account_ids: visible)
    end

    def panel_for(goal)
      component_for(goal).panel
    end
end
