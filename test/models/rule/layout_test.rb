require "test_helper"

class Rule::LayoutTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "lists groups and rules without a group by position" do
    loose = create_rule("Loose")
    group = @family.rule_groups.create!(name: "Food")
    grouped = create_rule("Grouped", group: group)
    later = create_rule("Later")

    assert_equal [ "rule:#{loose.id}", "group:#{group.id}", "rule:#{later.id}" ], layout.items.map(&:key)
    assert_equal [ grouped ], layout.items.second.rules
  end

  test "a rule joining a group runs at the end of that group" do
    group = @family.rule_groups.create!(name: "Food")
    first_in_group = create_rule("First in group", group: group)
    loose = create_rule("Loose")
    joining = create_rule("Joining")

    joining.update!(rule_group: group)

    assert_equal [ first_in_group, joining, loose ], @family.rules.ordered.to_a
    assert_equal [ first_in_group, joining ], layout.items.first.rules
  end

  test "a rule leaving a group stays right below it" do
    group = @family.rule_groups.create!(name: "Food")
    staying = create_rule("Staying", group: group)
    leaving = create_rule("Leaving", group: group)
    loose = create_rule("Loose")

    leaving.update!(rule_group: nil)

    assert_equal [ "group:#{group.id}", "rule:#{leaving.id}", "rule:#{loose.id}" ], layout.items.map(&:key)
    assert_equal [ staying, leaving, loose ], @family.rules.ordered.to_a
  end

  test "placing a rule in a group leaves the items above it alone" do
    above = create_rule("Above")
    group = @family.rule_groups.create!(name: "Food")
    joining = create_rule("Joining")

    assert_no_changes -> { above.reload.position } do
      joining.update!(rule_group: group)
    end
    assert_equal [ "rule:#{above.id}", "group:#{group.id}" ], layout.items.map(&:key)
  end

  test "reorder! moves a group together with its rules" do
    loose = create_rule("Loose")
    group = @family.rule_groups.create!(name: "Food")
    first_in_group = create_rule("First", group: group)
    second_in_group = create_rule("Second", group: group)

    layout.reorder!([ "group:#{group.id}", "rule:#{loose.id}" ])

    assert_equal [ first_in_group, second_in_group, loose ], @family.rules.ordered.to_a
    assert_equal [ "group:#{group.id}", "rule:#{loose.id}" ], layout.items.map(&:key)
  end

  test "reorder! rejects stale, foreign and duplicate keys" do
    loose = create_rule("Loose")
    group = @family.rule_groups.create!(name: "Food")
    grouped = create_rule("Grouped", group: group)
    foreign = rules(:one)
    before = @family.rules.ordered.pluck(:id, :position)

    assert_raises(ArgumentError) { layout.reorder!([ "rule:#{loose.id}" ]) }
    assert_raises(ArgumentError) { layout.reorder!([ "rule:#{loose.id}", "group:#{group.id}", "rule:#{foreign.id}" ]) }
    assert_raises(ArgumentError) { layout.reorder!([ "rule:#{loose.id}", "rule:#{loose.id}" ]) }
    # A rule inside a group is not a top-level item.
    assert_raises(ArgumentError) { layout.reorder!([ "rule:#{loose.id}", "rule:#{grouped.id}" ]) }

    assert_equal before, @family.rules.ordered.pluck(:id, :position)
    assert_equal 1, foreign.reload.position
  end

  test "reorder_group! orders the rules inside a group and keeps its place" do
    before_group = create_rule("Before")
    group = @family.rule_groups.create!(name: "Food")
    first_in_group = create_rule("First", group: group)
    second_in_group = create_rule("Second", group: group)
    after_group = create_rule("After")

    layout.reorder_group!(group, [ second_in_group.id, first_in_group.id ])

    assert_equal [ before_group, second_in_group, first_in_group, after_group ], @family.rules.ordered.to_a
  end

  test "reorder_group! rejects rules outside the group" do
    group = @family.rule_groups.create!(name: "Food")
    grouped = create_rule("Grouped", group: group)
    loose = create_rule("Loose")

    assert_raises(ArgumentError) { layout.reorder_group!(group, [ grouped.id, loose.id ]) }
    assert_raises(ArgumentError) { layout.reorder_group!(group, []) }
  end

  test "deleting a group keeps its rules in place without a group" do
    before_group = create_rule("Before")
    group = @family.rule_groups.create!(name: "Food")
    first_in_group = create_rule("First", group: group)
    second_in_group = create_rule("Second", group: group)
    after_group = create_rule("After")

    group.destroy!

    assert_equal [ before_group, first_in_group, second_in_group, after_group ], @family.rules.ordered.to_a
    assert_equal [ before_group, first_in_group, second_in_group, after_group ].map { |rule| "rule:#{rule.id}" }, layout.items.map(&:key)
    assert_nil first_in_group.reload.rule_group_id
  end

  test "an empty group keeps its place" do
    first = create_rule("First")
    group = @family.rule_groups.create!(name: "Empty")
    last = create_rule("Last")

    layout.reorder!([ "rule:#{last.id}", "group:#{group.id}", "rule:#{first.id}" ])

    assert_equal [ "rule:#{last.id}", "group:#{group.id}", "rule:#{first.id}" ], layout.items.map(&:key)
  end

  private
    def layout
      Rule::Layout.new(@family)
    end

    def create_rule(name, group: nil)
      @family.rules.create!(name: name, resource_type: "transaction", rule_group: group,
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
end
