class DataCacheClearJob < ApplicationJob
  queue_as :low_priority

  # Market data is refreshed before anything is deleted: the holdings decide
  # which security prices are needed, and the account syncs must start with
  # the refreshed exchange rates.
  def perform(family)
    Family::MarketDataRefresher.new(family).refresh

    ActiveRecord::Base.transaction do
      Balance.where(account_id: family.accounts.select(:id)).delete_all
      Holding.where(account_id: family.accounts.select(:id)).delete_all

      family.sync_later
    end
  end
end
