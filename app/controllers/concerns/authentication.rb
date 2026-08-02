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

    # Resolves the signed session cookie to a Session record. Deactivation can
    # happen at any point after the cookie was already issued (e.g. an admin
    # deactivates the user while their browser is still signed in elsewhere),
    # so this re-checks the user's active status on every request instead of
    # only at sign-in. A stale session belonging to a deactivated user is
    # destroyed here so it can't be reused again, not just skipped.
    def find_session_by_cookie
      cookie_value = cookies.signed[:session_token]
      return nil if cookie_value.blank?

      session_record = Session.includes(:user).find_by(id: cookie_value)
      return nil unless session_record

      unless session_record.user&.active?
        Rails.logger.warn("[AUTH] Rejected session for deactivated user_id=#{session_record.user_id}")
        session_record.destroy
        return nil
      end

      session_record
    end

    # Shared by every sign-in path (local password, MFA completion, SSO,
    # desktop/mobile exchange) so a deactivated account can't get a fresh
    # session through any of them. Returns nil instead of raising so each
    # caller can redirect with its own context-appropriate messaging.
    def create_session_for(user)
      unless user.active?
        Rails.logger.warn("[AUTH] Rejected session creation for deactivated user_id=#{user.id}")
        return nil
      end

      session = user.sessions.create!
      cookies.signed.permanent[:session_token] = { value: session.id, httponly: true }
      session
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
