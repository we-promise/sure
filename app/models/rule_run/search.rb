class RuleRun::Search
  include ScopedSearch

  attribute :rule_id, :string
  attribute :status, :string
  attribute :execution_type, :string
  attribute :start_executed_at, :datetime
  attribute :end_executed_at, :datetime

  def rule_runs_scope
    relation = scope
    relation = relation.where(rule_id:) unless rule_id.nil?
    relation = relation.where(status:) unless status.nil?
    relation = relation.where(execution_type:) unless execution_type.nil?
    within_range(relation, :executed_at, start_executed_at, end_executed_at)
  end
end
