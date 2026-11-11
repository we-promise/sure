# Rebuilds every account after a market data provider setting changes.
#
# Settings are instance-wide, so every family's accounts are affected. Account
# syncs fetch the rates and prices each account needs and recalculate its
# balances. They are queued per account rather than through family syncs,
# which only reach linked accounts after a successful import from their
# provider (see MarketDataResetJob).
#
# An account whose sync already started may have imported market data with the
# old settings, and Syncable#sync_later would fold a new request into it, so
# those accounts are retried once that sync has finished.
class MarketDataRefreshJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 30.seconds
  MAX_ATTEMPTS = 20

  def perform(account_ids = nil, attempts_remaining: MAX_ATTEMPTS)
    accounts = account_ids ? Account.where(id: account_ids) : Account.all
    running_ids = Sync.visible.syncing.where(syncable_type: "Account").pluck(:syncable_id).to_set

    deferred_ids = []
    accounts.find_each do |account|
      if running_ids.include?(account.id)
        deferred_ids << account.id
        next
      end

      account.sync_later
    rescue => e
      Rails.logger.error("MarketDataRefreshJob failed to sync account #{account.id}: #{e.message}")
    end

    return if deferred_ids.empty?

    if attempts_remaining.positive?
      self.class.set(wait: RETRY_DELAY).perform_later(deferred_ids, attempts_remaining: attempts_remaining - 1)
    else
      Rails.logger.warn("MarketDataRefreshJob gave up waiting for running syncs of accounts #{deferred_ids.join(', ')}")
    end
  end
end
