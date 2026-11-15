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
#
# Retries back off up to MAX_RETRY_DELAY and continue until WAIT_LIMIT has
# passed. A sync still running by then is older than Sync::STALE_AFTER, so it
# is treated as lost (SyncCleanerJob marks it stale) and a fresh sync is
# queued anyway. No account is dropped while its sync is still running.
class MarketDataRefreshJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 30.seconds
  MAX_RETRY_DELAY = 15.minutes
  WAIT_LIMIT = Sync::STALE_AFTER + 1.hour

  # Queues a refresh, recording a failure to queue in the debug log instead of
  # raising, so a settings change still succeeds when the queue is down.
  def self.refresh_later(source:, family: nil, user: nil)
    perform_later
  rescue StandardError => error
    DebugLogEntry.capture(
      category: "background_jobs",
      level: "error",
      message: "Failed to queue market data refresh after a provider setting changed",
      source: source,
      family: family,
      user: user,
      metadata: { error_class: error.class.name, error_message: error.message }
    )
  end

  def perform(account_ids = nil, attempt: 0, first_attempt_at: Time.current)
    accounts = account_ids ? Account.where(id: account_ids) : Account.all
    running_ids = Sync.syncing.where(syncable_type: "Account").pluck(:syncable_id).to_set
    final_attempt = first_attempt_at <= WAIT_LIMIT.ago

    retry_ids = []
    accounts.find_each do |account|
      if running_ids.include?(account.id) && !final_attempt
        retry_ids << account.id
        next
      end

      begin
        log_replaced_sync(account) if running_ids.include?(account.id)
        account.sync_later
      rescue => e
        retry_ids << account.id
        log_queue_failure(account, e)
      end
    end

    return if retry_ids.empty?

    if final_attempt
      log_gave_up(retry_ids)
    else
      self.class.set(wait: retry_delay(attempt))
        .perform_later(retry_ids, attempt: attempt + 1, first_attempt_at: first_attempt_at)
    end
  end

  private
    def retry_delay(attempt)
      [ RETRY_DELAY * (2**attempt.clamp(0, 10)), MAX_RETRY_DELAY ].min
    end

    def log_replaced_sync(account)
      DebugLogEntry.capture(
        category: "background_jobs",
        level: "warn",
        message: "Account #{account.id} was still syncing after the refresh waited #{WAIT_LIMIT.inspect}; queued a sync to refresh market data",
        source: self.class.name,
        account: account
      )
    end

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
          metadata: { wait_limit_seconds: WAIT_LIMIT.to_i }
        )
      end
    end
end
