class Holding::CurrentPositions
  # Read provider links afresh so a connection made on this account is visible.
  def initialize(account)
    @account = account
  end

  # Combine complete provider snapshots with individually published and manual
  # positions, without reviving assets omitted from a newer complete snapshot.
  def scope
    holdings = @account.holdings.where(date: ..Date.current)
    links = AccountProvider.where(account_id: @account.id).includes(:provider).to_a
    complete_provider_ids = links.filter_map do |link|
      link.id unless link.adapter&.position_only?
    end
    latest = holdings.where(account_provider_id: complete_provider_ids).group(:account_provider_id).maximum(:date)
    provider_security_ids = holdings.where(account_provider_id: complete_provider_ids).select(:security_id)
    eligible = holdings.where(account_provider_id: nil).where.not(security_id: provider_security_ids)
    position_ids = links.map(&:id) - complete_provider_ids
    eligible = eligible.or(holdings.where(account_provider_id: position_ids))
    latest.each { |provider_id, date| eligible = eligible.or(holdings.where(account_provider_id: provider_id, date: date)) }

    @account.holdings.where(id: eligible.select("DISTINCT ON (security_id) id").order(:security_id, date: :desc))
      .where.not(qty: 0).order(amount: :desc)
  end
end
