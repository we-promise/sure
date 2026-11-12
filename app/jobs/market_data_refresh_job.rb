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
# those accounts are retried once that sync has finished. Running syncs are
# found without the Sync.visible window: sync_later stops reusing a sync after
# that window, so a long-running sync would otherwise get a concurrent twin.
# Accounts whose sync could not be queued are retried the same way.
class MarketDataRefreshJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 30.seconds
  MAX_ATTEMPTS = 20

  def perform(account_ids = nil, attempts_remaining: MAX_ATTEMPTS)
    accounts = account_ids ? Account.where(id: account_ids) : Account.all
    running_ids = Sync.syncing.where(syncable_type: "Account").pluck(:syncable_id).to_set

    retry_ids = []
    accounts.find_each do |account|
      if running_ids.include?(account.id)
        retry_ids << account.id
        next
      end

      begin
        account.sync_later
      rescue => e
        retry_ids << account.id
        log_queue_failure(account, e)
      end
    end

    return if retry_ids.empty?

    if attempts_remaining.positive?
      self.class.set(wait: RETRY_DELAY).perform_later(retry_ids, attempts_remaining: attempts_remaining - 1)
    else
      log_gave_up(retry_ids)
    end
  end

  private
    def log_queue_failure(account, error)
      DebugLogEntry.capture(
        category: "background_jobs",
        level: "error",
        message: "Failed to queue market data refresh sync for account #{account.id}",
        source: self.class.name,
        account: account,
        metadata: { error_class: error.class.name, error_message: error.message }
      )
    end

    def log_gave_up(account_ids)
      Account.where(id: account_ids).find_each do |account|
        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "Gave up refreshing market data for account #{account.id}; it will refresh on its next sync",
          source: self.class.name,
          account: account,
          metadata: { max_attempts: MAX_ATTEMPTS }
        )
      end
    end
end
