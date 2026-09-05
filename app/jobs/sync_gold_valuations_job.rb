# Refreshes active physical-gold accounts once each day so their balances and
# net-worth history reflect the latest available spot price.
class SyncGoldValuationsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Account.active.where(accountable_type: "Investment").includes(:accountable, :family).find_each do |account|
      next unless account.investment&.physical_gold?
      next unless account.investment.gold_details_complete?

      GoldValuation.new(account:).refresh!
    rescue GoldValuation::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      DebugLogEntry.capture(
        category: "gold_valuation",
        level: "error",
        message: error.message,
        source: self.class.name,
        family: account.family,
        account: account,
        metadata: { account_id: account.id }
      )
    end
  end
end
