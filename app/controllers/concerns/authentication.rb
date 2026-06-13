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

    def find_session_by_cookie
      cookie_value = cookies.signed[:session_token]
      return nil unless cookie_value.present?

      session_record = Session.includes(:user, active_impersonator_session: :impersonated).find_by(id: cookie_value)
      return clear_invalid_session(session_record) unless session_record&.user&.active?

      clear_inactive_impersonation(session_record)

      session_record
    end

    def clear_inactive_impersonation(session_record)
      impersonated_user = session_record.active_impersonator_session&.impersonated
      return if impersonated_user.blank? || impersonated_user.active?

      session_record.update!(active_impersonator_session: nil)
    end

    def clear_invalid_session(session_record)
      session_record&.destroy
      cookies.delete(:session_token)
      nil
    end

    def create_session_for(user)
      session = user.sessions.create!
      cookies.signed.permanent[:session_token] = { value: session.id, httponly: true }
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
