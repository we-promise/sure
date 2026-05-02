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
      else
        if self_hosted_first_login?
          redirect_to new_registration_url
        else
          redirect_to new_session_url
        end
      end
    end

    # Session TTL constants (F-04, CWE-613)
    SESSION_ABSOLUTE_TTL = 30.days
    SESSION_IDLE_TTL = 24.hours
    # Throttle the per-request `updated_at` touch so every authenticated request
    # doesn't issue a write against `sessions`. 1 minute is granular enough for
    # the 24h idle TTL while keeping write amplification bounded.
    SESSION_TOUCH_THROTTLE = 1.minute

    def find_session_by_cookie
      cookie_value = cookies.signed[:session_token]
      return nil unless cookie_value.present?

      session = Session.find_by(id: cookie_value)
      unless session
        # Stale cookie (session row was deleted or recycled) — remove it so the
        # browser doesn't keep resending a dead token.
        cookies.delete(:session_token)
        return nil
      end

      now = Time.current

      # Absolute TTL: session older than 30 days is always expired
      if session.created_at < now - SESSION_ABSOLUTE_TTL
        session.destroy
        cookies.delete(:session_token)
        return nil
      end

      # Idle TTL: session not used in 24h is expired
      if session.updated_at < now - SESSION_IDLE_TTL
        session.destroy
        cookies.delete(:session_token)
        return nil
      end

      # Refresh idle timer, throttled to avoid a write per request.
      session.touch if session.updated_at < now - SESSION_TOUCH_THROTTLE
      session
    end

    # Resets the Rails session to prevent session fixation on privilege change
    # (login, MFA verify) while preserving the pending invitation token stored
    # pre-login. `reset_session` clears everything by default, which would drop
    # a legitimate pending invitation before `accept_pending_invitation_for`
    # could use it.
    def reset_session_preserving_pending_invitation
      pending_invitation = session[:pending_invitation_token]
      reset_session
      session[:pending_invitation_token] = pending_invitation if pending_invitation
    end

    def create_session_for(user)
      session = user.sessions.create!
      cookies.signed.permanent[:session_token] = {
        value: session.id,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }
      session
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
