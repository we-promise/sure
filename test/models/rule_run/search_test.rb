require "test_helper"

class RuleRun::SearchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @rule = create_rule("Search rule")
    @other_rule = create_rule("Other search rule")

    @manual = create_run(@rule, execution_type: "manual", status: "success", executed_at: Time.zone.parse("2024-01-15 12:00:00"))
    @scheduled = create_run(@rule, execution_type: "scheduled", status: "failed", executed_at: Time.zone.parse("2024-01-16 12:00:00"))
    @immediate = create_run(@other_rule, execution_type: "immediate", status: "pending", executed_at: Time.zone.parse("2024-01-17 12:00:00"))
    @scope = RuleRun.where(id: [ @manual, @scheduled, @immediate ])
  end

  test "without filters returns the scope it is given" do
    assert_equal [ @manual, @scheduled, @immediate ].sort_by(&:id), RuleRun::Search.new(@scope).rule_runs_scope.sort_by(&:id)
  end

  test "filters by rule" do
    assert_equal [ @immediate ], search(rule_id: @other_rule.id).to_a
  end

  test "filters by status and execution type" do
    assert_equal [ @scheduled ], search(status: "failed").to_a
    assert_equal [ @manual ], search(execution_type: "manual").to_a
    assert_empty search(status: "failed", execution_type: "manual")
  end

  test "filters by an inclusive execution window" do
    assert_equal [ @scheduled, @immediate ].sort_by(&:id), search(start_executed_at: @scheduled.executed_at).sort_by(&:id)
    assert_equal [ @manual, @scheduled ].sort_by(&:id), search(end_executed_at: @scheduled.executed_at).sort_by(&:id)
    assert_equal [ @scheduled ], search(start_executed_at: @scheduled.executed_at, end_executed_at: @scheduled.executed_at).to_a
  end

  test "never widens the scope it is given" do
    assert_empty RuleRun::Search.new(@scope.where(rule: @rule), filters: { rule_id: @other_rule.id }).rule_runs_scope
  end

  private

    def search(filters)
      RuleRun::Search.new(@scope, filters:).rule_runs_scope
    end

    def create_rule(name)
      rule = @family.rules.build(name:, resource_type: "transaction", active: true)
      rule.conditions.build(condition_type: "transaction_name", operator: "like", value: name)
      rule.actions.build(action_type: "set_transaction_name", value: name)
      rule.tap(&:save!)
    end

    def create_run(rule, execution_type:, status:, executed_at:)
      rule.rule_runs.create!(
        rule_name: rule.name, execution_type:, status:, executed_at:,
        transactions_queued: 1, transactions_processed: 1, transactions_modified: 0, pending_jobs_count: 0
      )
    end
end
