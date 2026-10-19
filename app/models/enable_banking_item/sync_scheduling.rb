# frozen_string_literal: true

module EnableBankingItem::SyncScheduling
  extend ActiveSupport::Concern

  MIN_SYNC_INTERVAL = 15.minutes
  TRANSIENT_RETRY_DELAYS = [ 5.minutes, 15.minutes, 1.hour ].freeze
  PSU_CONTEXT_KEY = "enable_banking_context".freeze
  PSU_CONTEXT_MAX_AGE = 2.minutes
  PSU_CONTEXT_FUTURE_SKEW = 5.seconds
  PSU_USER_AGENT_MAX_BYTES = 512

  SyncDeferredError = Class.new(StandardError)

  def sync_budget_key
    return if application_id.blank? || aspsp_name.blank? || country_code.blank?

    Digest::SHA256.hexdigest([ application_id, aspsp_name, country_code ].join("\0"))
  end

  def enable_banking_sync_budget
    EnableBankingSyncBudget.for_item(self)
  end

  def sync_rate_limited_until
    shared_deadline = enable_banking_sync_budget&.rate_limited_until
    own_deadline = sync_retry_reason == "rate_limited" ? next_sync_at : nil
    [ shared_deadline, own_deadline ].compact.max
  end

  def sync_rate_limited?(at: Time.current)
    deadline = sync_rate_limited_until
    deadline.present? && deadline > at
  end

  # manual sync eligibility excludes the ordinary six-hour background cadence.
  def sync_eligible_at
    [ next_sync_at, enable_banking_sync_budget&.rate_limited_until ].compact.max
  end

  def next_background_sync_at
    enable_banking_sync_budget&.next_background_sync_at
  end

  def background_sync_waiting?(at: Time.current)
    next_background_sync_at.present? && next_background_sync_at > at
  end

  def sync_retry_at
    return unless sync_retry_reason.present? || sync_rate_limited?

    [ sync_eligible_at, next_background_sync_at ].compact.max
  end

  def sync_cooldown?
    sync_eligible_at.present? && sync_eligible_at > Time.current
  end

  def sync_retry_pending?
    return false if needs_authorization?

    (sync_retry_reason.present? && sync_retry_at.present?) || sync_rate_limited?
  end

  def sync_cooldown_message
    key = if sync_rate_limited?
      "rate_limited"
    elsif sync_retry_pending?
      "retrying"
    else
      "cooldown"
    end
    time = if sync_retry_pending?
      sync_retry_at
    else
      sync_eligible_at.presence || next_background_sync_at
    end
    return if time.blank?

    formatted_time = "#{I18n.l(time, format: :short)} #{Time.zone.name}"
    I18n.t("enable_banking_items.sync.#{key}", time: formatted_time)
  end

  def interactive_psu_context(ip_address:, user_agent:, user:, session:)
    return unless ActiveRecordEncryptionConfig.ready?
    return unless user&.admin? && user.active? && user.family_id == family_id
    return unless session&.persisted? && session.user_id == user.id
    return if session_id.blank?
    return if session.active_impersonator_session_id.present?
    return if ip_address.blank? || user_agent.blank?

    ip = IPAddr.new(ip_address.to_s).to_s
    agent = user_agent.to_s.byteslice(0, PSU_USER_AGENT_MAX_BYTES)
    return if agent.blank?

    {
      "ip_address" => ip,
      "user_agent" => agent,
      "requested_at" => Time.current.iso8601(6),
      "user_id" => user.id.to_s,
      "session_id" => session.id.to_s,
      "session_fingerprint" => session_fingerprint
    }
  rescue IPAddr::InvalidAddressError
    nil
  end

  def sync_later(psu_context: nil, **options)
    with_lock do
      return if scheduled_for_deletion?
      context = validate_psu_context(psu_context)
      return if sync_cooldown?

      budget = enable_banking_sync_budget
      if budget
        sync = budget.reserve_for_sync!(item: self, online: context.present?) { super(**options) }
        return unless sync

        store_psu_context!(sync, context) if context
        sync
      else
        sync = super(**options)
        store_psu_context!(sync, context) if sync && context
        sync
      end
    end
  end

  def reserve_sync_slot!(sync:, psu_context: nil)
    with_lock do
      return :invalid_session unless session_valid?

      context = validate_psu_context(psu_context, sync: sync)
      online = context.present?
      now = Time.current
      eligible_at = sync_eligible_at
      return false if eligible_at.present? && eligible_at > now

      budget = enable_banking_sync_budget
      return false if budget && !budget.reserve_execution!(sync, online: online, at: now)

      update!(next_sync_at: [ next_sync_at, now + MIN_SYNC_INTERVAL ].compact.max)
      { psu_context: context, psu_headers: build_psu_headers(psu_context: context) }
    end
  end

  def release_sync_reservation!(sync)
    enable_banking_sync_budget&.release_sync!(sync)
  end

  def with_sync_lock
    reload
    if (budget = enable_banking_sync_budget)
      budget.with_bank_lock do
        reload
        unless enable_banking_sync_budget&.id == budget.id
          raise SyncDeferredError, "The Enable Banking connection changed while its sync was queued."
        end

        yield
      end
    else
      key = Digest::SHA256.hexdigest("enable-banking-sync:#{id}").first(15).to_i(16)
      self.class.connection_pool.with_connection do |connection|
        locked = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        raise SyncDeferredError, I18n.t("enable_banking_items.sync.in_progress") unless locked == true || locked.to_s == "t"

        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
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
        # keep the existing 6h, 12h, then 24h fallback when Enable Banking omits Retry-After.
        [ error.retry_after || 6.hours * (2**[ attempt - 1, 2 ].min), MIN_SYNC_INTERVAL ].max
      else
        TRANSIENT_RETRY_DELAYS.fetch(attempt - 1)
      end
      requested_retry_at = delay.from_now
      item_deadline = [ next_sync_at, requested_retry_at ].compact.max

      update!(next_sync_at: item_deadline, sync_retry_count: attempt,
              sync_retry_reason: error.rate_limited? ? "rate_limited" : "temporary_error")
      item_deadline
    end

    budget = enable_banking_sync_budget
    budget&.extend_rate_limit!(retry_at) if error.rate_limited?
    automatic_retry_at = [ retry_at, budget&.rate_limited_until, budget&.next_background_sync_at ].compact.max
    retry_token = [ retry_at.iso8601(6), automatic_retry_at.iso8601(6) ].join("|")

    begin
      job = EnableBankingSyncRetryJob.set(wait_until: automatic_retry_at).perform_later(self, retry_token)
      raise ActiveJob::EnqueueError, "Retry job was not accepted" unless job
    rescue => e
      # the hourly scheduler recovers persisted retry intent if enqueue fails.
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
                  retry_at: automatic_retry_at.iso8601, attempt: sync_retry_count, http_status: error.http_status }
    )
    automatic_retry_at
  end

  def consume_psu_context!(sync)
    encrypted_context = nil
    sync.with_lock do
      data = (sync.data || {}).to_h.deep_stringify_keys
      encrypted_context = data.delete(PSU_CONTEXT_KEY)
      sync.update!(data: data.presence) if encrypted_context
    end
    return unless encrypted_context.present? && ActiveRecordEncryptionConfig.ready?

    payload = JSON.parse(ActiveRecord::Encryption.encryptor.decrypt(encrypted_context))
    validate_psu_context(payload, sync: sync)
  rescue ActiveRecord::Encryption::Errors::Base, JSON::ParserError, TypeError, ArgumentError
    nil
  end

  private

    def validate_psu_context(context, sync: nil)
      return unless context.respond_to?(:to_h) && ActiveRecordEncryptionConfig.ready?

      payload = context.to_h.deep_stringify_keys
      requested_at = Time.iso8601(payload.fetch("requested_at"))
      return if requested_at < PSU_CONTEXT_MAX_AGE.ago || requested_at > PSU_CONTEXT_FUTURE_SKEW.from_now

      user = User.find_by(id: payload["user_id"])
      session = Session.find_by(id: payload["session_id"])
      return unless user&.admin? && user.active? && user.family_id == family_id
      return unless session&.user_id == user.id && session.active_impersonator_session_id.blank?
      return if payload["ip_address"].blank? || payload["user_agent"].blank?
      return unless IPAddr.new(payload["ip_address"]).to_s == payload["ip_address"]
      return unless payload["user_agent"].to_s.bytesize <= PSU_USER_AGENT_MAX_BYTES
      return unless payload["family_id"].blank? || payload["family_id"].to_s == family_id.to_s
      return unless payload["item_id"].blank? || payload["item_id"].to_s == id.to_s
      return unless payload["session_fingerprint"].blank? || payload["session_fingerprint"] == session_fingerprint
      return if sync && (payload["sync_id"].to_s != sync.id.to_s || sync.syncable_type != self.class.base_class.name || sync.syncable_id != id)

      if sync
        return unless payload["family_id"].to_s == family_id.to_s
        return unless payload["item_id"].to_s == id.to_s
        return unless payload["session_fingerprint"] == session_fingerprint
      end
      verified = payload.slice(
        "ip_address", "user_agent", "requested_at", "user_id", "session_id",
        "family_id", "item_id", "sync_id", "session_fingerprint"
      )
      return if build_psu_headers(psu_context: verified).blank?

      verified
    rescue IPAddr::InvalidAddressError, KeyError, ArgumentError
      nil
    end

    def store_psu_context!(sync, context)
      payload = context.merge(
        "family_id" => family_id.to_s,
        "item_id" => id.to_s,
        "sync_id" => sync.id.to_s,
        "session_fingerprint" => session_fingerprint
      )
      encrypted_context = ActiveRecord::Encryption.encryptor.encrypt(payload.to_json)

      sync.with_lock do
        data = (sync.data || {}).to_h.deep_stringify_keys
        data[PSU_CONTEXT_KEY] = encrypted_context
        sync.update!(data: data)
      end
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end

    def session_fingerprint
      return if session_id.blank?

      Digest::SHA256.hexdigest(session_id.to_s)
    end
end
