class Holding::CurrentPositions
  # Bind the account without depending on preloaded provider associations.
  def initialize(account)
    @account = account
  end

  # Combine published and manual positions; a publisher's row takes precedence
  # over a newer manual row for the same security.
  def scope
    position_ids = AccountProvider.where(account_id: @account.id).pluck(:id)
    eligible = @account.holdings.where(date: ..Date.current, account_provider_id: [ nil, *position_ids ])
    position_priority = Arel::Nodes::Case.new
      .when(Holding.arel_table[:account_provider_id].in(position_ids)).then(0)
      .else(1)

    @account.holdings.where(id: eligible.select("DISTINCT ON (security_id) id").order(:security_id, position_priority, date: :desc))
      .where.not(qty: 0).order(amount: :desc)
  end
end
