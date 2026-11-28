class Category::Search
  include ScopedSearch

  attribute :roots_only, :boolean
  attribute :parent_id, :string

  def categories_scope
    relation = scope
    relation = relation.roots if roots_only
    relation = relation.where(parent_id:) unless parent_id.nil?
    relation
  end
end
