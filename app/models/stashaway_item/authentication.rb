# Signing in to StashAway: email and password, then an SMS code when
# StashAway asks for one. The password is passed through to StashAway and
# not stored unless the user asks for it to be kept; the item keeps the
# email, the API token and, between the two steps, the token the password
# step returned.
#
# A saved password, encrypted and only offered when encryption is
# configured, lets StashawayItem::Syncer sign in again by itself when
# StashAway stops accepting the token. It is saved only once StashAway
# accepted it, and a sign-in that does not ask to keep it drops it.
#
# StashAway says when it wants the code (the password step answers 401
# "2FA" with a token for the code steps). It asks for the code only the
# first time it sees a device, so a later sign-in with the same device id
# is expected to go through on the password alone; that step's token is
# tried for portfolio data first, and the code is only sent when StashAway
# does not serve it.
module StashawayItem::Authentication
  extend ActiveSupport::Concern

  # How long the code step stays open. StashAway decides how long its own
  # login token lasts; this only stops a stale one being offered for ever.
  LOGIN_CODE_WINDOW = 10.minutes

  class LoginExpired < StandardError; end
  # The StashAway login is connected through another of the family's items
  # in the same region.
  class AlreadyConnected < StandardError; end
  # A new sign-in reached a different StashAway login than the one whose
  # portfolios this item holds.
  class AccountMismatch < StandardError; end

  included do
    before_validation :assign_device_id, on: :create
  end

  def login_pending?
    pending_login_token.present? && pending_login_started_at.present? && pending_login_started_at > LOGIN_CODE_WINDOW.ago
  end

  def login_expired?
    pending_login_token.present? && !login_pending?
  end

  # Saves the item, a new one included, only once StashAway accepted the
  # password. Returns :connected when the item can sync, :code_sent when
  # StashAway sent an SMS code for #complete_login!.
  #
  # remember: keep the password so the syncer can sign in again by itself.
  # It is kept only encrypted, so never without encryption configured.
  def start_login!(password:, remember: false)
    client = stashaway_client
    session = client.login(email: email, password: password, device_id: device_id)
    # Refused here so that a login that is already connected costs no SMS
    # code; the check that counts runs again when the item is saved.
    claim_stashaway_login!(session.user_id)
    self.password = remember && self.class.encryption_ready? ? password : nil

    if session.two_factor_required
      record_login_step("StashAway asked for an SMS code")
      client.send_two_factor_code(token: session.token)
      claim_and_save!(session.user_id) do
        update!(pending_login_token: session.token, pending_login_started_at: Time.current, status: :requires_update)
      end
      :code_sent
    elsif client.usable_token?(session.token)
      record_login_step("the password step's token is accepted for data")
      claim_and_save!(session.user_id) { connect!(session.token) }
      :connected
    else
      record_login_step("the password step's token is not accepted for data; sending an SMS code")
      client.send_two_factor_code(token: session.token)
      claim_and_save!(session.user_id) do
        update!(pending_login_token: session.token, pending_login_started_at: Time.current, status: :requires_update)
      end
      :code_sent
    end
  end

  def complete_login!(code:)
    raise LoginExpired unless login_pending?

    connect!(stashaway_client.verify_two_factor(code: code, token: pending_login_token, device_id: device_id))
    :connected
  end

  def resend_login_code!
    raise LoginExpired unless login_pending?

    stashaway_client.send_two_factor_code(token: pending_login_token)
    update!(pending_login_started_at: Time.current)
  end

  def cancel_login!
    update!(pending_login_token: nil, pending_login_started_at: nil)
  end

  def forget_password!
    update!(password: nil)
  end

  # StashAway stopped accepting the token. A saved password stays: the
  # syncer signs in with it again, and only StashAway refusing it drops it.
  def require_reauthentication!
    update!(api_token: nil, status: :requires_update)
  end

  private

    def assign_device_id
      self.device_id ||= SecureRandom.uuid
    end

    def connect!(token)
      update!(api_token: token, pending_login_token: nil, pending_login_started_at: nil, status: :good)
    end

    # Two sign-ins of one login can pass the duplicate check together, so
    # the check and the save share the family's row lock. StashAway is not
    # called while it is held.
    def claim_and_save!(user_id)
      family.with_lock do
        claim_stashaway_login!(user_id)
        yield
      end
    end

    # The password step's answer carries a user id only sometimes; the SMS
    # flow gives none, so the email stands in for it then.
    def claim_stashaway_login!(user_id)
      raise AccountMismatch if user_id.present? && stashaway_user_id.present? && stashaway_user_id != user_id

      # Logins are per region: the same user id or email elsewhere is
      # another login.
      others = family.stashaway_items.active.where(region: region)
      others = others.where.not(id: id) if persisted?
      raise AlreadyConnected if user_id.present? && others.exists?(stashaway_user_id: user_id)
      raise AlreadyConnected if others.any? { |other| other.email.to_s.casecmp?(email.to_s) }

      self.stashaway_user_id = user_id if user_id.present?
    end

    # Which way StashAway's unverified sign-in went, for the debug log. The
    # password never goes in here.
    def record_login_step(outcome)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "StashAway sign-in: #{outcome}",
        source: "stashaway",
        family: family,
        provider_key: "stashaway"
      )
    end
end
