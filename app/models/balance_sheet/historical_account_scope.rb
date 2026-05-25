class BalanceSheet::HistoricalAccountScope
  def self.ids_for(family, user:) = (user.present? ? family.accounts.historical.included_in_finances_for(user) : family.accounts.historical).pluck(:id)
end
