module EnableBankingItem::SyncScheduling
  extend ActiveSupport::Concern

  MIN_SYNC_INTERVAL = 15.minutes
  TRANSIENT_RETRY_DELAYS = [ 5.minutes, 15.minutes, 1.hour ].freeze
  SyncDeferredError = Class.new(StandardError)

  def sync_cooldown?
    next_sync_at.present? && next_sync_at > Time.current
  end

  def sync_retry_pending?
    sync_retry_reason.present? && next_sync_at.present? && !needs_authorization?
  end

  def sync_cooldown_message
    key = sync_retry_reason == "rate_limited" ? "rate_limited" : (sync_retry_pending? ? "retrying" : "cooldown")
    I18n.t("enable_banking_items.sync.#{key}", time: I18n.l(next_sync_at, format: :short))
  end

  def sync_later(**options)
    with_lock do
      return if sync_cooldown? || scheduled_for_deletion?

      super
    end
  end

  def reserve_sync_slot!
    with_lock do
      raise SyncDeferredError, sync_cooldown_message if sync_cooldown?

      update!(next_sync_at: MIN_SYNC_INTERVAL.from_now)
    end
  end

  def with_sync_lock
    key = Digest::SHA256.hexdigest("enable-banking-sync:#{id}").first(15).to_i(16)
    self.class.connection_pool.with_connection do |connection|
      locked = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
      raise SyncDeferredError, I18n.t("enable_banking_items.sync.in_progress") unless locked

      begin
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{key})")
      end
    end
  end

  def schedule_sync_retry!(error)
    retry_at = with_lock do
      attempt = sync_retry_count + 1
      unless error.rate_limited? || attempt <= TRANSIENT_RETRY_DELAYS.length
        update!(sync_retry_reason: nil, sync_retry_count: 0)
        return false
      end

      delay = if error.rate_limited?
        # absent an upstream deadline, back off conservatively: 6h, 12h, then 24h
        [ error.retry_after || 6.hours * (2**[ attempt - 1, 2 ].min), MIN_SYNC_INTERVAL ].max
      else
        TRANSIENT_RETRY_DELAYS.fetch(attempt - 1)
      end

      update!(next_sync_at: delay.from_now, sync_retry_count: attempt,
              sync_retry_reason: error.rate_limited? ? "rate_limited" : "temporary_error")
      next_sync_at
    end

    begin
      job = EnableBankingSyncRetryJob.set(wait_until: retry_at).perform_later(self, retry_at.iso8601(6))
      raise ActiveJob::EnqueueError, "Retry job was not accepted" unless job
    rescue => e
      # the existing hourly sweep recovers persisted retry intent if enqueue fails
      DebugLogEntry.capture(
        category: "provider_sync_retry_enqueue_failed", level: :error,
        message: "Enable Banking retry will be recovered by the hourly scheduler",
        source: "EnableBankingItem::SyncScheduling", provider_key: "enable_banking", family: family,
        metadata: { enable_banking_item_id: id, error_class: e.class.name }
      )
    end
    DebugLogEntry.capture(
      category: "provider_sync_deferred", level: :warn,
      message: "Enable Banking sync deferred; saved balances and transactions retained",
      source: "EnableBankingItem::SyncScheduling", provider_key: "enable_banking", family: family,
      metadata: { enable_banking_item_id: id, reason: sync_retry_reason,
                  retry_at: retry_at.iso8601, attempt: sync_retry_count, http_status: error.http_status }
    )
    true
  end
end
