require "test_helper"

class Goal::RetirementTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @sibling = users(:family_member)
    @stranger = users(:empty)
  end

  test "STI: Goal.find returns Goal::Retirement instance" do
    retirement = Goal::Retirement.create!(
      family: @family,
      owner: @owner,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    fetched = Goal.find(retirement.id)
    assert_instance_of Goal::Retirement, fetched
    assert_equal "Goal::Retirement", fetched.type
  end

  test "requires owner" do
    retirement = Goal::Retirement.new(
      family: @family,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert_not retirement.valid?
    assert_includes retirement.errors[:owner], "can't be blank"
  end

  test "owner must belong to family" do
    retirement = Goal::Retirement.new(
      family: @family,
      owner: @stranger,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert_not retirement.valid?
    assert_match(/belong to the same family/i, retirement.errors[:owner].join(" "))
  end

  test "editable_by? owner true, sibling false, stranger false, nil false" do
    retirement = Goal::Retirement.create!(
      family: @family,
      owner: @owner,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert retirement.editable_by?(@owner)
    assert_not retirement.editable_by?(@sibling)
    assert_not retirement.editable_by?(@stranger)
    assert_not retirement.editable_by?(nil)
  end

  test "no linked_accounts required (parent validation bypassed)" do
    retirement = Goal::Retirement.new(
      family: @family,
      owner: @owner,
      name: "Retirement",
      target_amount: 1_000_000,
      currency: "USD"
    )

    assert retirement.valid?, retirement.errors.full_messages.to_sentence
  end

  test "for_owner bootstraps a valid plan without a target_amount" do
    # family_member has no retirement fixture, so this exercises the
    # create path (family_admin would just find retirement_bob).
    member = users(:family_member)

    plan = Goal::Retirement.for_owner(member)

    assert plan.persisted?
    assert_nil plan.target_amount
    assert_equal member.id, plan.user_id
    assert_equal member.family_id, plan.family_id
  end

  test "for_owner is idempotent (one plan per user)" do
    member = users(:family_member)
    first = Goal::Retirement.for_owner(member)
    second = Goal::Retirement.for_owner(member)
    assert_equal first.id, second.id
  end

  test "has pension sources, statements, adjustments, and bucket accounts" do
    plan = goals(:retirement_bob)
    assert_includes plan.pension_sources, pension_sources(:de_grv_bob)
    assert_includes plan.statements, goal_retirement_statements(:grv_2025)
    assert_includes plan.adjustments, goal_retirement_adjustments(:mortgage_paid_off)
    assert_includes plan.bucket_accounts, accounts(:investment)
  end

  test "adjustments are capped at ADJUSTMENTS_LIMIT" do
    plan = goals(:retirement_bob)

    (plan.adjustments.size...Goal::Retirement::ADJUSTMENTS_LIMIT).each do |i|
      plan.adjustments.build(from_age: 60, amount_today: -1, currency: "USD", label: "adj #{i}", ordinal: i + 1)
    end
    assert plan.valid?, plan.errors.full_messages.to_sentence

    plan.adjustments.build(from_age: 61, amount_today: -1, currency: "USD", label: "over", ordinal: 99)
    assert_not plan.valid?
    assert_includes plan.errors.attribute_names, :adjustments
  end
end
