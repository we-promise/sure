require "test_helper"

class GoalsHelperTest < ActionView::TestCase
  include GoalsHelper

  setup do
    @family = families(:dylan_family)
    @account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Helper Savings", currency: "USD", balance: 6_000
    )
  end

  test "sums the fixed earmarks other goals hold on the account" do
    build_goal("A", 2_000)
    build_goal("B", 1_500)

    assert_equal BigDecimal("3500"), earmarked_by_other_goals(@account, pooled: pooled)
  end

  # The whole point of the helper: reopening a goal must not count itself.
  test "excludes the goal currently being edited" do
    mine = build_goal("Mine", 5_000)
    build_goal("Theirs", 500)

    assert_equal BigDecimal("500"), earmarked_by_other_goals(@account, pooled: pooled, current_goal: mine)
  end

  test "a goal that does not exist yet excludes nothing" do
    build_goal("Existing", 2_000)
    unsaved = @family.goals.new(name: "New", target_amount: 1_000, currency: "USD")

    assert_equal BigDecimal("2000"), earmarked_by_other_goals(@account, pooled: pooled, current_goal: unsaved)
  end

  test "whole-balance links reserve no fixed slice" do
    build_goal("Whole", nil)

    assert_equal BigDecimal("0"), earmarked_by_other_goals(@account, pooled: pooled)
  end

  test "an account no goal touches has nothing earmarked" do
    untouched = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Untouched", currency: "USD", balance: 1_000
    )

    assert_equal BigDecimal("0"), earmarked_by_other_goals(untouched, pooled: pooled)
  end

  # Depends on Lot B1: both released states drop out of the pool, so neither
  # can inflate the headroom warning.
  test "archived and completed goals are absent from the pool" do
    archived = build_goal("Archived", 1_000)
    completed = build_goal("Completed", 1_000)
    build_goal("Live", 750)

    archived.archive!
    completed.complete!

    assert_equal BigDecimal("750"), earmarked_by_other_goals(@account, pooled: pooled)
  end


  # A whole-account link carries a nil allocation, so it sums to zero — the
  # figure alone cannot tell "nobody else claims this account" from "another
  # goal claims all of it". The second refuses a blank allocation at the door,
  # so a form that reads them the same way promises something it cannot keep.
  test "a whole-account claim is invisible to the sum but not to the predicate" do
    build_goal("Whole", nil)

    assert_equal BigDecimal("0"), earmarked_by_other_goals(@account, pooled: pooled)
    assert whole_account_claimed_by_other_goals?(@account, pooled: pooled)
  end

  test "fixed earmarks alone leave the account unclaimed as a whole" do
    build_goal("A", 2_000)

    assert_not whole_account_claimed_by_other_goals?(@account, pooled: pooled)
  end

  # The goal being edited never counts against itself, on either reading.
  test "the goal being edited is excluded from the whole-account check" do
    mine = build_goal("Mine", nil)

    assert_not whole_account_claimed_by_other_goals?(@account, pooled: pooled, current_goal: mine)
  end

  private
    def build_goal(name, allocated)
      @family.goals.create!(name: name, target_amount: 10_000, currency: "USD") do |g|
        g.goal_accounts.build(account: @account, allocated_amount: allocated)
      end
    end

    def pooled
      Goal.pooled_allocations_for(@family)
    end
end
