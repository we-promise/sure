class Account::Search
  include ScopedSearch

  attribute :include_disabled, :boolean

  def accounts_scope
    include_disabled ? scope : scope.visible
  end
end
