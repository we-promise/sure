module Authentication
  extend ActiveSupport::Concern

  REMOTE_HEADER_SSO_PROVIDER = "remote_user_header"

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
      cookie_session = find_session_by_cookie

      if cookie_session && cookie_session_disagrees_with_header?(cookie_session)
        cookie_session.destroy
        cookies.delete(:session_token)
        cookie_session = nil
      end

      if cookie_session
        Current.session = cookie_session
      elsif session_record = create_session_by_remote_header
        Current.session = session_record
      else
        if self_hosted_first_login?
          redirect_to new_registration_url
        else
          redirect_to new_session_url
        end
      end
    end

    def cookie_session_disagrees_with_header?(session)
      email = trusted_remote_user_email
      email.present? && session.user.email != email
    end

    def create_session_by_remote_header
      return unless user_email = trusted_remote_user_email

      user, created = find_or_create_remote_header_user(user_email)
      if created
        SsoAuditLog.log_jit_account_created!(
          user: user,
          provider: REMOTE_HEADER_SSO_PROVIDER,
          request: request
        )
      end
      SsoAuditLog.log_login!(
        user: user,
        provider: REMOTE_HEADER_SSO_PROVIDER,
        request: request
      )
      create_session_for(user)
    end

    # Returns the email asserted by the upstream proxy, but only when the
    # request passes all configured trust gates: self-hosted mode, header
    # set, source IP in the trusted-proxies allowlist, shared-secret match
    # (if configured), and email shape is valid.
    def trusted_remote_user_email
      return nil unless Rails.application.config.app_mode.self_hosted?

      header_name = Rails.application.config.remote_user_header_email
      return nil if header_name.blank?
      return nil unless remote_user_proxy_trusted?
      return nil unless remote_user_secret_valid?

      email = request.headers[header_name]&.strip&.downcase
      return nil if email.blank?
      return nil unless URI::MailTo::EMAIL_REGEXP.match?(email)

      email
    end

    def remote_user_proxy_trusted?
      trusted = Rails.application.config.remote_user_trusted_proxies
      peer_ip = IPAddr.new(request.env["REMOTE_ADDR"])
      trusted.any? { |range| range.include?(peer_ip) }
    rescue IPAddr::Error
      false
    end

    def remote_user_secret_valid?
      expected = Rails.application.config.remote_user_shared_secret
      return true if expected.blank?

      provided = request.headers[Rails.application.config.remote_user_shared_secret_header].to_s
      ActiveSupport::SecurityUtils.secure_compare(expected, provided)
    end

    def find_or_create_remote_header_user(user_email)
      if user = User.find_by(email: user_email)
        [ user, false ]
      else
        # Leave password_digest nil so the user can't fall back to local
        # password login or password reset; the proxy is the only path in.
        user = User.new
        user.email = user_email
        user.skip_password_validation = true
        user.family = Family.new
        user.role = User.role_for_new_family_creator(fallback_role: :admin)
        begin
          user.save!
          [ user, true ]
        rescue ActiveRecord::RecordNotUnique
          [ User.find_by!(email: user_email), false ]
        end
      end
    end

    def find_session_by_cookie
      cookie_value = cookies.signed[:session_token]

      if cookie_value.present?
        Session.find_by(id: cookie_value)
      else
        nil
      end
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
