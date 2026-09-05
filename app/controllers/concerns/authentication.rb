module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :set_request_details
    before_action :authenticate_user!
    before_action :set_sentry_user
  end

  class_methods do
    def skip_authentication(**options)
      skip_before_action :authenticate_user!, **options
      skip_before_action :set_sentry_user, **options
    end
  end

  # Rails session keys that survive the sign-in rotation. An invitation the
  # user followed before signing in must still be accepted afterwards.
  SESSION_KEYS_KEPT_ON_SIGN_IN = %i[pending_invitation_token].freeze
  # Stored by the OIDC callback for RP-initiated logout. Kept only when the
  # session being minted comes from that same OIDC sign-in.
  SESSION_KEYS_OIDC_HANDOFF = %i[id_token_hint sso_login_provider].freeze
  private_constant :SESSION_KEYS_KEPT_ON_SIGN_IN, :SESSION_KEYS_OIDC_HANDOFF

  private
    def authenticate_user!
      if session_record = find_session_by_cookie
        Current.session = session_record
        end_impersonation_if_target_inactive!
      else
        if self_hosted_first_login?
          redirect_to new_registration_url
        else
          redirect_to new_session_url
        end
      end
    end

    def find_session_by_cookie
      cookie_value = cookies.signed[:session_token]
      return if cookie_value.blank?

      session_record = Session.includes(:user).find_by(id: cookie_value)
      return session_record if session_record&.user&.active?

      session_record&.destroy!
      cookies.delete(:session_token)
      nil
    end

    # Every sign-in path (password, OIDC, passkey, desktop exchange, MFA) mints
    # its session here, so this is where the pre-auth Rails session is rotated
    # to prevent fixation (CWE-384). Only an OIDC sign-in should ask to keep
    # the federated-logout keys it just stored.
    def create_session_for(user, preserve_oidc_handoff: false)
      return false unless user&.persisted?

      user.with_lock do
        next false unless user.active?

        rotate_rails_session(preserve_oidc_handoff: preserve_oidc_handoff)
        session = user.sessions.create!
        cookies.signed.permanent[:session_token] = { value: session.id, httponly: true }
        session
      end
    rescue ActiveRecord::RecordNotFound
      false
    end

    # Parks the user between the first factor and MFA. Only an OIDC sign-in
    # carries federated-logout keys into the handoff; every other path drops
    # whatever a previous OIDC session left behind, so a stale id_token_hint
    # can never be replayed into a locally authenticated session.
    def begin_mfa_handoff(user, from_oidc: false)
      SESSION_KEYS_OIDC_HANDOFF.each { |key| session.delete(key) } unless from_oidc
      session[:mfa_user_id] = user.id
    end

    def rotate_rails_session(preserve_oidc_handoff:)
      keys = SESSION_KEYS_KEPT_ON_SIGN_IN
      keys += SESSION_KEYS_OIDC_HANDOFF if preserve_oidc_handoff
      kept = keys.index_with { |key| session[key] }.compact_blank

      reset_session
      kept.each { |key, value| session[key] = value }
    end

    # If a super admin is currently impersonating a user who gets deactivated
    # mid-session, end the impersonation (same mechanism as
    # ImpersonationSessionsController#leave) rather than logging the admin out
    # entirely — their own session is still valid.
    def end_impersonation_if_target_inactive!
      impersonation = Current.session&.active_impersonator_session
      return unless impersonation && !impersonation.impersonated.active?

      Rails.logger.warn(
        "[AUTH] Ending impersonation_session_id=#{impersonation.id}: " \
        "impersonated user_id=#{impersonation.impersonated_id} is deactivated"
      )
      Current.session.update!(active_impersonator_session: nil)
    end

    def self_hosted_first_login?
      Rails.application.config.app_mode.self_hosted? && User.count.zero?
    end

    def set_request_details
      Current.user_agent = request.user_agent
      Current.ip_address = request.ip
    end

    def set_sentry_user
      return unless defined?(Sentry) && ENV["SENTRY_DSN"].present?

      if Current.user
        Sentry.set_user(
          id: Current.user.id,
          email: Current.user.email,
          username: Current.user.display_name,
          ip_address: Current.ip_address
        )
      end
    end
end
