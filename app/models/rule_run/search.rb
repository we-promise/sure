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
    relation = relation.where(executed_at: start_executed_at..) unless start_executed_at.nil?
    relation = relation.where(executed_at: ..end_executed_at) unless end_executed_at.nil?
    relation
  end
end
