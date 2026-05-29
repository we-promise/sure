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
end
