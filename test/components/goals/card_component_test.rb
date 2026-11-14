require "test_helper"

class Goals::CardComponentTest < ViewComponent::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  # The card used to print the unmeasured pace as a measured zero:
  # "$0/mo · target $900/mo".
  test "a goal whose pace cannot be measured says so rather than showing a zero" do
    component = Goals::CardComponent.new(goal: unmeasurable_goal)
    target = Money.new(900, "USD").format(precision: 0)

    assert_equal I18n.t("goals.goal_card.pace_unknown_with_target", target: target), component.pace_line
    assert_not_includes component.pace_line, Money.new(0, "USD").format(precision: 0)
  end

  test "the card's accessible name names the unmeasured status" do
    label = Goals::CardComponent.new(goal: unmeasurable_goal).aria_label

    assert_includes label, I18n.t("goals.status.pace_unknown")
    assert_not_includes label, "translation missing"
  end

  private
    # 9,000 to find over 10 months: 900/mo required. The only account carries
    # an opening balance and nothing since, so there is no pace to measure.
    def unmeasurable_goal
      account = Account.create!(family: @family, accountable: Depository.new,
                                name: "Anchored #{SecureRandom.hex(3)}", currency: "USD", balance: 1_000)
      create_valuation(account: account, amount: 1_000, date: 30.days.ago.to_date, kind: "opening_anchor")
      @family.goals.create!(name: "Trip", target_amount: 10_000, target_date: 300.days.from_now.to_date,
                            currency: "USD") { |g| g.goal_accounts.build(account: account) }
    end
end
