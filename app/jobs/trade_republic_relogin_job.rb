# The opt-in daily Trade Republic login: starts the push login at the item's
# auto_login_time so the user only has to approve it in the Trade Republic
# app. The old session keeps working while the new one is pending.
#
# Every schedule has a token (TradeRepublicItem#auto_login_token). Changing or
# clearing the setting replaces it, which makes every job of the earlier
# schedule, including its retries, do nothing.
class TradeRepublicReloginJob < ApplicationJob
  queue_as :scheduled

  # An unapproved login is retried every RETRY_DELAY until the old session
  # ends, at most MAX_ATTEMPTS times per day.
  RETRY_DELAY = 30.minutes
  MAX_ATTEMPTS = 6

  # Starts a new schedule from what the row holds now, not from the instance
  # that was saved: callbacks of overlapping saves can run out of order, and
  # the last one to run must not undo a newer setting.
  def self.schedule_for(item)
    token = nil
    current = TradeRepublicItem.transaction do
      row = TradeRepublicItem.lock.find_by(id: item.id)
      next unless row

      token = SecureRandom.uuid if row.auto_login_time.present?
      row.update_columns(auto_login_token: token, auto_login_planned_for: nil)
      row
    end
    return unless token

    begin
      plan(current, token)
    rescue StandardError
      # Without a queued start the schedule would only look active; a later
      # save of the item sees no token and starts it again.
      TradeRepublicItem.where(id: item.id, auto_login_token: token).update_all(auto_login_token: nil, auto_login_planned_for: nil)
      raise
    end
  end

  # Queues the next start once per schedule and time: a rerun of a day's first
  # attempt (after an error, say) finds it claimed and queues nothing, which
  # keeps the schedule one chain.
  def self.plan(item, token)
    at = item.next_auto_login_at
    claimed = TradeRepublicItem.where(id: item.id, auto_login_token: token)
      .where("auto_login_planned_for IS NULL OR auto_login_planned_for < ?", at)
      .update_all(auto_login_planned_for: at)
    return if claimed.zero?

    begin
      set(wait_until: at).perform_later(item, token: token, attempt: 1)
    rescue StandardError
      # Not queued after all, so the claim must not block the rerun.
      TradeRepublicItem.where(id: item.id, auto_login_planned_for: at).update_all(auto_login_planned_for: nil)
      raise
    end
  end

  # What marks the session a cycle started from: a session replaced since then
  # (by a manual login, say) ends the cycle.
  def self.session_stamp(item)
    item.session_expires_at.to_i
  end

  def self.current?(item, token)
    token.present? && TradeRepublicItem.where(id: item.id, auto_login_token: token).where.not(auto_login_time: nil).exists?
  end

  # After a failed attempt: another one later while the window lasts, else
  # the admins are told once. Rate limiting and other hard errors pass
  # retryable: false, since asking again would only hammer Trade Republic.
  def self.attempt_failed(item, token:, attempt:, window_ends_at:, session_stamp: nil, retryable: true)
    return unless current?(item, token)

    retry_at = RETRY_DELAY.from_now
    if retryable && attempt < MAX_ATTEMPTS && retry_at.to_i <= window_ends_at
      set(wait_until: retry_at).perform_later(
        item, token: token, attempt: attempt + 1, window_ends_at: window_ends_at, session_stamp: session_stamp
      )
    else
      log(item, "warn", "failed after #{attempt} attempt(s), the admins are told")
      notify_admins(item)
    end
  end

  def self.notify_admins(item)
    item.family.users.where(role: %w[admin super_admin]).find_each do |admin|
      TradeRepublicMailer.with(user: admin).auto_login_failed.deliver_later
    end
  end

  # Never put the PIN, the pending login or provider messages in here: error
  # messages can quote the provider's response.
  def self.log(item, level, message)
    DebugLogEntry.capture(
      category: "sync",
      level: level,
      message: "Trade Republic scheduled login for item #{item.id}: #{message}",
      source: "trade_republic",
      family: item.family,
      provider_key: "trade_republic"
    )
  end

  def perform(item, token:, attempt:, window_ends_at: nil, session_stamp: nil)
    return unless self.class.current?(item, token)

    session_stamp ||= self.class.session_stamp(item)
    return if self.class.session_stamp(item) != session_stamp

    window_ends_at ||= window_end_for(item)
    failure = { token: token, attempt: attempt, window_ends_at: window_ends_at, session_stamp: session_stamp }
    # A day's first attempt also plans the next day.
    self.class.plan(item, token) if attempt == 1
    return if item.scheduled_for_deletion?
    # The user is logging in by hand. One who left a login unapproved only
    # holds the slot until it lapses, which the browser alone would clear.
    pending = item.pending_login_state
    if pending.present?
      return unless Provider::TradeRepublicClient.pending_login_lapsed?(pending)
      return unless item.update_if_pending_login_current!(pending, pending_login_state: nil)
    end

    # A retry is only an earliest start time; a late one must not push after the window.
    if attempt > 1 && Time.current.to_i > window_ends_at
      self.class.log(item, "info", "the retry came after its window")
      return self.class.attempt_failed(item, retryable: false, **failure)
    end

    if item.pin.blank? || item.phone_number.blank?
      self.class.log(item, "info", "no PIN or phone number stored")
      return self.class.attempt_failed(item, retryable: false, **failure)
    end

    result = item.trade_republic_provider.initiate_login
    if result["method"] != "push"
      self.class.log(item, "info", "the account needs an authenticator code")
      return self.class.attempt_failed(item, retryable: false, **failure)
    end

    pending = result["pending_login_b64"]
    return unless item.update_if_pending_login_current!(nil, token: token, pending_login_state: pending)

    begin
      TradeRepublicReloginPollJob.set(wait: TradeRepublicReloginPollJob::POLL_INTERVAL).perform_later(
        item, pending_digest: TradeRepublicReloginPollJob.digest(pending), **failure
      )
    rescue StandardError
      # Nothing will poll this login, and a pending one would block every later
      # start. A login the user began meanwhile has another state and stays.
      item.update_if_pending_login_current!(pending, pending_login_state: nil)
      raise
    end
  rescue Provider::TradeRepublicClient::RateLimited => e
    self.class.log(item, "warn", "rate limited (#{e.class})")
    self.class.attempt_failed(item, retryable: false, **failure)
  rescue Provider::TradeRepublicClient::Error => e
    self.class.log(item, "warn", "could not start (attempt #{attempt}): #{e.class}")
    self.class.attempt_failed(item, **failure)
  end

  private

    # While the old session lasts, attempts may go on until it ends; once it
    # ended there is no such limit, so the attempt cap sets the window.
    def window_end_for(item)
      expires_at = item.session_expires_at
      return expires_at.to_i if expires_at&.future?

      (RETRY_DELAY * MAX_ATTEMPTS).from_now.to_i
    end
end
