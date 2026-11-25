class Rule::Search
  include ScopedSearch

  attribute :resource_type, :string
  attribute :active, :boolean

  def rules_scope
    relation = scope
    relation = relation.where(resource_type:) unless resource_type.nil?
    relation = relation.where(active:) unless active.nil?
    relation
  end
end
