class Import::Search
  include ScopedSearch

  attribute :status, :string
  attribute :type, :string

  def imports_scope
    relation = scope
    relation = relation.where(status:) unless status.nil?
    relation = relation.where(type:) unless type.nil?
    relation
  end
end
