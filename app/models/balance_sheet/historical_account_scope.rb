class BalanceSheet::HistoricalAccountScope
  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # The last date each disabled account in `accounts` still counts for: the
  # day before it was disabled (or before it was last updated, when
  # disabled_at is unset). One definition for every historical series -- net
  # worth and the investment statement's -- so a closed account leaves both
  # charts on the same day.
  def self.active_until_dates(accounts)
    accounts.each_with_object({}) do |account, dates|
      next unless account.disabled?

      disabled_on = (account.disabled_at || account.updated_at).to_date
      dates[account.id] = disabled_on - 1.day
    end
  end

  def account_ids
    relation.pluck(:id)
  end

  def relation
    scope = family.accounts.historical.included_in_reports
    user.present? ? scope.included_in_finances_for(user) : scope
  end

  private
    attr_reader :family, :user
end
