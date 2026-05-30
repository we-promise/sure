class BalanceSheet::HistoricalAccountScope
  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  def account_ids
    relation.pluck(:id)
  end

  def relation
    scope = family.accounts.historical
    user.present? ? scope.included_in_finances_for(user) : scope
  end

  private
    attr_reader :family, :user
end
