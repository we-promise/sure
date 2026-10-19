# frozen_string_literal: true

module ProviderSyncPacing
  extend ActiveSupport::Concern

  MIN_SYNC_INTERVAL = 5.minutes
  DEFAULT_RATE_LIMIT_COOLDOWN = 15.minutes
  MAX_RATE_LIMIT_COOLDOWN = 7.days

  def sync_eligible_at(lane: :sync)
    last_attempt_at = public_send(sync_attempt_column(lane))
    [ last_attempt_at && last_attempt_at + MIN_SYNC_INTERVAL, next_sync_at ].compact.max
  end

  def sync_cooldown?(lane: :sync, at: Time.current)
    eligible_at = sync_eligible_at(lane: lane)
    eligible_at.present? && eligible_at > at
  end

  def sync_rate_limited?(at: Time.current)
    next_sync_at.present? && next_sync_at > at
  end

  def sync_cooldown_message(lane: :sync)
    eligible_at = sync_eligible_at(lane: lane)
    return unless eligible_at

    reason = sync_rate_limited? ? "rate_limited" : "cooldown"
    I18n.t("#{sync_pacing_translation_scope}.#{reason}", time: I18n.l(eligible_at, format: :short))
  end

  def reserve_sync_attempt!(lane: :sync, at: Time.current)
    with_lock do
      return false if sync_cooldown?(lane: lane, at: at)

      update!(sync_attempt_column(lane) => at)
      true
    end
  end

  def record_rate_limit!(retry_after: nil, expected_generation: nil, updates: {}, at: Time.current)
    retry_at = rate_limit_deadline(retry_after, at: at)

    with_lock do
      next if expected_generation && connection_generation != expected_generation

      update!(updates.merge(next_sync_at: [ next_sync_at, retry_at ].compact.max))
    end
  end

  def clear_sync_rate_limit!
    update!(next_sync_at: nil) if next_sync_at.present? && next_sync_at <= Time.current
  end

  def with_provider_sync_lock
    lock_key = Digest::SHA256.hexdigest("provider-sync-pacing:#{self.class.base_class.name}:#{id}").first(15).to_i(16)

    self.class.connection_pool.with_connection do |connection|
      locked = connection.select_value("SELECT pg_try_advisory_lock(#{lock_key})")
      next false unless locked == true || locked.to_s == "t"

      begin
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{lock_key})")
      end
    end
  end

  def sync_later(**options)
    with_lock do
      return if sync_cooldown? || (respond_to?(:scheduled_for_deletion?) && scheduled_for_deletion?)

      super
    end
  end

  private

    def rate_limit_deadline(retry_after, at:)
      seconds = retry_after_seconds(retry_after, at: at)
      delay = if seconds
        [ seconds, MIN_SYNC_INTERVAL.to_i ].max.clamp(MIN_SYNC_INTERVAL.to_i, MAX_RATE_LIMIT_COOLDOWN.to_i)
      else
        DEFAULT_RATE_LIMIT_COOLDOWN.to_i
      end
      at + delay
    end

    def retry_after_seconds(value, at:)
      raw = value.to_s.strip
      return if raw.empty? || raw.bytesize > 128
      return Integer(raw, 10) if raw.match?(/\A\d+\z/)

      [ Time.httpdate(raw) - at, 0 ].max.ceil
    rescue ArgumentError, TypeError
      nil
    end

    def sync_attempt_column(_lane)
      :last_sync_attempt_at
    end

    def sync_pacing_translation_scope
      raise NotImplementedError
    end
end
