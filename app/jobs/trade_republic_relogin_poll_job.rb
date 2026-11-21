# Polls the push login started by TradeRepublicReloginJob until the user
# approves it, the login lapses (about two minutes) or Trade Republic refuses.
# The old session stays in place until the new one is confirmed.
class TradeRepublicReloginPollJob < ApplicationJob
  queue_as :scheduled

  POLL_INTERVAL = 7.seconds

  def self.digest(pending)
    Digest::SHA256.hexdigest(pending.to_s)
  end

  def perform(item, pending_digest:, token:, attempt:, window_ends_at:, session_stamp: nil)
    cycle = { token: token, attempt: attempt, window_ends_at: window_ends_at, session_stamp: session_stamp }
    # The schedule was changed or switched off, or a new session arrived
    # meanwhile (a manual login): this cycle is done.
    return release_pending(item, pending_digest) unless TradeRepublicReloginJob.current?(item, token)
    return release_pending(item, pending_digest) if session_stamp && TradeRepublicReloginJob.session_stamp(item) != session_stamp

    pending = item.pending_login_state
    # The browser's own poll can see the login lapse first and clear it; the
    # attempt still failed, so it still gets its retries.
    return give_up(item, nil, "the login ended without a new session", cycle, retryable: true) if pending.blank?
    # A manual login replaced the one this job polls.
    return if self.class.digest(pending) != pending_digest

    result = item.trade_republic_provider.complete_login(pending_login_b64: pending)

    if result.data["status"] == "pending"
      poll_again(item, pending, result.data["pending_login_b64"], pending_digest, cycle)
    else
      outcome = item.finish_login(pending, result, token: token)
      item.sync_later if outcome == :completed && !item.syncing?
    end
  rescue Provider::TradeRepublicClient::Timeout, Provider::TradeRepublicClient::TransientProviderError
    # The login lapses by itself, which ends the polling.
    poll_again(item, pending, nil, pending_digest, cycle)
  rescue Provider::TradeRepublicClient::LoginExpired, Provider::TradeRepublicClient::AuthenticationRequired
    give_up(item, pending, "the login was not approved in time", cycle, retryable: true)
  rescue Provider::TradeRepublicClient::Error => e
    give_up(item, pending, "the login failed (#{e.class})", cycle, retryable: false)
  end

  private

    # A pending login of this cycle that nobody polls anymore would make the
    # next scheduled start think the user is logging in; clear it. One that
    # belongs to a login by hand stays.
    def release_pending(item, pending_digest)
      pending = item.pending_login_state
      return if pending.blank? || self.class.digest(pending) != pending_digest

      item.update_if_pending_login_current!(pending, pending_login_state: nil)
    end

    def poll_again(item, pending, next_pending, pending_digest, cycle)
      if next_pending.present? && next_pending != pending
        return unless item.update_if_pending_login_current!(pending, pending_login_state: next_pending)

        pending_digest = self.class.digest(next_pending)
      end

      self.class.set(wait: POLL_INTERVAL).perform_later(item, pending_digest: pending_digest, **cycle)
    end

    # Clears only the pending login; the session and status stay, so the
    # item falls back to the manual login once the session really ends.
    def give_up(item, pending, reason, cycle, retryable:)
      return unless item.update_if_pending_login_current!(pending, pending_login_state: nil)

      TradeRepublicReloginJob.log(item, "info", "#{reason} (attempt #{cycle[:attempt]})")
      TradeRepublicReloginJob.attempt_failed(item, retryable: retryable, **cycle)
    end
end
