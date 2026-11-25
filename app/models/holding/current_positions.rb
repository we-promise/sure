class Holding::CurrentPositions
  # Bind the account without depending on preloaded provider associations.
  def initialize(account)
    @account = account
  end

  # Journal replay can value a published position after its last wallet read.
  # A manual snapshot cannot replace a published position.
  def scope
    position_ids = AccountProvider.where(account_id: @account.id).pluck(:id)
    eligible = @account.holdings.where(date: ..Date.current, superseded: false, account_provider_id: [ nil, *position_ids ])
    published_securities = eligible.where.not(account_provider_id: nil).select(:security_id)
    holdings = Holding.arel_table
    manual_override = holdings[:account_provider_id].eq(nil)
      .and(holdings[:materialized].eq(false))
      .and(holdings[:security_id].in(published_securities.arel))
    position_priority = Arel::Nodes::Case.new.when(manual_override).then(1).else(0)

    latest = eligible.joins(:account).select("DISTINCT ON (holdings.security_id) holdings.id")
      .reorder(holdings[:security_id], position_priority, holdings[:date].desc, Arel.sql(Holding::POSITION_ORDER))

    @account.holdings.where(id: latest).where.not(qty: 0).order(amount: :desc)
  end
end
