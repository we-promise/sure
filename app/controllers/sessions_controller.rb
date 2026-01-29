class SessionsController < ApplicationController
  before_action :set_session, only: :destroy
  skip_authentication only: %i[index new create openid_connect failure post_logout mobile_sso_start]

  layout "auth"

  # Handle GET /sessions (usually from browser back button)
  def index
    redirect_to new_session_path
  end

  def new
    begin
      demo = Rails.application.config_for(:demo)
      @prefill_demo_credentials = demo_host_match?(demo)
      if @prefill_demo_credentials
        @email = params[:email].presence || demo["email"]
        @password = params[:password].presence || demo["password"]
      else
        @email = params[:email]
        @password = params[:password]
      end
    rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError
      # Demo config file missing or malformed - disable demo credential prefilling
      @prefill_demo_credentials = false
      @email = params[:email]
      @password = params[:password]
    end
  end

  def create
    user = nil

    if AuthConfig.local_login_enabled?
      user = User.authenticate_by(email: params[:email], password: params[:password])
    else
      # Local login is disabled. Only allow attempts when an emergency super-admin
      # override is enabled and the email belongs to a super-admin.
      if AuthConfig.local_admin_override_enabled?
        candidate = User.find_by(email: params[:email])
        unless candidate&.super_admin?
          redirect_to new_session_path, alert: t("sessions.create.local_login_disabled")
          return
        end

        user = User.authenticate_by(email: params[:email], password: params[:password])
      else
        redirect_to new_session_path, alert: t("sessions.create.local_login_disabled")
        return
      end
    end

    if user
      if user.otp_required?
        log_super_admin_override_login(user)
        session[:mfa_user_id] = user.id
        redirect_to verify_mfa_path
      else
        log_super_admin_override_login(user)
        @session = create_session_for(user)
        redirect_to root_path
      end
    else
      flash.now[:alert] = t(".invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    user = Current.user
    id_token = session[:id_token_hint]
    login_provider = session[:sso_login_provider]

    # Find the identity for the provider used during login, with fallback to first if session data lost
    oidc_identity = if login_provider.present?
      user.oidc_identities.find_by(provider: login_provider)
    else
      user.oidc_identities.first
    end

    # Destroy local session
    @session.destroy
    session.delete(:id_token_hint)
    session.delete(:sso_login_provider)

    # Check if we should redirect to IdP for federated logout
    if oidc_identity && id_token.present?
      idp_logout_url = build_idp_logout_url(oidc_identity, id_token)

      if idp_logout_url
        SsoAuditLog.log_logout_idp!(user: user, provider: oidc_identity.provider, request: request)
        redirect_to idp_logout_url, allow_other_host: true
        return
      end
    end

    # Standard local logout
    SsoAuditLog.log_logout!(user: user, request: request)
    redirect_to new_session_path, notice: t(".logout_successful")
  end

  # Handle redirect back from IdP after federated logout
  def post_logout
    redirect_to new_session_path, notice: t(".logout_successful")
  end

  def mobile_sso_start
    provider = params[:provider].to_s
    configured_providers = Rails.configuration.x.auth.sso_providers.map { |p| p[:name].to_s }

    unless configured_providers.include?(provider)
      redirect_to "sureapp://oauth/callback?error=invalid_provider&message=#{CGI.escape('SSO provider not configured')}",
        allow_other_host: true
      return
    end

    unless params[:device_id].present? && params[:device_name].present? && params[:device_type].present?
      redirect_to "sureapp://oauth/callback?error=missing_device_info&message=#{CGI.escape('Device information is required')}",
        allow_other_host: true
      return
    end

    session[:mobile_sso] = {
      device_id: params[:device_id],
      device_name: params[:device_name],
      device_type: params[:device_type],
      os_version: params[:os_version],
      app_version: params[:app_version]
    }

    # Render auto-submitting form to POST to OmniAuth (required by omniauth-rails_csrf_protection)
    render inline: <<~HTML, layout: false, content_type: "text/html"
      <!DOCTYPE html>
      <html><body>
        <form id="sso_form" action="/auth/#{ERB::Util.html_escape(provider)}" method="post">
          <input type="hidden" name="authenticity_token" value="#{form_authenticity_token}">
        </form>
        <script>document.getElementById('sso_form').submit();</script>
        <noscript><p>Redirecting to sign in... <a href="/auth/#{ERB::Util.html_escape(provider)}">Click here</a> if not redirected.</p></noscript>
      </body></html>
    HTML
  end

  def openid_connect
    auth = request.env["omniauth.auth"]

    # Nil safety: ensure auth and required fields are present
    unless auth&.provider && auth&.uid
      redirect_to new_session_path, alert: t("sessions.openid_connect.failed")
      return
    end

    # Security fix: Look up by provider + uid, not just email
    oidc_identity = OidcIdentity.find_by(provider: auth.provider, uid: auth.uid)

    if oidc_identity
      # Existing OIDC identity found - authenticate the user
      user = oidc_identity.user
      oidc_identity.record_authentication!
      oidc_identity.sync_user_attributes!(auth)

      # Log successful SSO login
      SsoAuditLog.log_login!(user: user, provider: auth.provider, request: request)

      # Mobile SSO: issue Doorkeeper tokens and redirect to app
      if session[:mobile_sso].present?
        if user.otp_required?
          session.delete(:mobile_sso)
          redirect_to "sureapp://oauth/callback?error=mfa_not_supported&message=#{CGI.escape('MFA users should sign in with email and password')}",
            allow_other_host: true
        else
          handle_mobile_sso_callback(user)
        end
        return
      end

      # Store id_token and provider for RP-initiated logout
      session[:id_token_hint] = auth.credentials&.id_token if auth.credentials&.id_token
      session[:sso_login_provider] = auth.provider

      # MFA check: If user has MFA enabled, require verification
      if user.otp_required?
        session[:mfa_user_id] = user.id
        redirect_to verify_mfa_path
      else
        @session = create_session_for(user)
        redirect_to root_path
      end
    else
      # Mobile SSO with no linked identity - redirect back with error
      if session[:mobile_sso].present?
        session.delete(:mobile_sso)
        redirect_to "sureapp://oauth/callback?error=account_not_linked&message=#{CGI.escape('Please link your Google account from the web app first')}",
          allow_other_host: true
        return
      end

      # No existing OIDC identity - need to link to account
      # Store auth data in session and redirect to linking page
      session[:pending_oidc_auth] = {
        provider: auth.provider,
        uid: auth.uid,
        email: auth.info&.email,
        name: auth.info&.name,
        first_name: auth.info&.first_name,
        last_name: auth.info&.last_name
      }
      redirect_to link_oidc_account_path
    end
  end

  def failure
    # Sanitize reason to known values only
    known_reasons = %w[sso_provider_unavailable sso_invalid_response sso_failed]
    sanitized_reason = known_reasons.include?(params[:message]) ? params[:message] : "sso_failed"

    # Log failed SSO attempt
    SsoAuditLog.log_login_failed!(
      provider: params[:strategy],
      request: request,
      reason: sanitized_reason
    )

    # Mobile SSO: redirect back to the app with error instead of web login page
    if session[:mobile_sso].present?
      session.delete(:mobile_sso)
      redirect_to "sureapp://oauth/callback?error=#{sanitized_reason}&message=#{CGI.escape('SSO authentication failed')}",
        allow_other_host: true
      return
    end

    message = case sanitized_reason
    when "sso_provider_unavailable"
      t("sessions.failure.sso_provider_unavailable")
    when "sso_invalid_response"
      t("sessions.failure.sso_invalid_response")
    else
      t("sessions.failure.sso_failed")
    end

    redirect_to new_session_path, alert: message
  end

  private
    def handle_mobile_sso_callback(user)
      device_info = session.delete(:mobile_sso)

      device = user.mobile_devices.find_or_initialize_by(device_id: device_info[:device_id])
      device.assign_attributes(
        device_name: device_info[:device_name],
        device_type: device_info[:device_type],
        os_version: device_info[:os_version],
        app_version: device_info[:app_version],
        last_seen_at: Time.current
      )

      unless device.save
        redirect_to "sureapp://oauth/callback?error=device_error&message=#{CGI.escape(device.errors.full_messages.join(', '))}",
          allow_other_host: true
        return
      end

      oauth_app = device.create_oauth_application!
      device.revoke_all_tokens!

      access_token = Doorkeeper::AccessToken.create!(
        application: oauth_app,
        resource_owner_id: user.id,
        expires_in: 30.days.to_i,
        scopes: "read_write",
        use_refresh_token: true
      )

      callback_params = {
        access_token: access_token.plaintext_token,
        refresh_token: access_token.plaintext_refresh_token,
        token_type: "Bearer",
        expires_in: access_token.expires_in,
        created_at: access_token.created_at.to_i,
        user_id: user.id,
        user_email: user.email,
        user_first_name: user.first_name,
        user_last_name: user.last_name
      }

      redirect_to "sureapp://oauth/callback?#{callback_params.to_query}", allow_other_host: true
    end

    def set_session
      @session = Current.user.sessions.find(params[:id])
    end

    def log_super_admin_override_login(user)
      # Only log when local login is globally disabled but an emergency
      # super-admin override is enabled.
      return if AuthConfig.local_login_enabled?
      return unless AuthConfig.local_admin_override_enabled?
      return unless user&.super_admin?

      Rails.logger.info("[AUTH] Super admin override login: user_id=#{user.id} email=#{user.email}")
    end

    def demo_host_match?(demo)
      return false unless demo.present? && demo["hosts"].present?

      demo["hosts"].include?(request.host)
    end

    def build_idp_logout_url(oidc_identity, id_token)
      # Find the provider configuration using unified loader (supports both YAML and DB providers)
      provider_config = ProviderLoader.load_providers.find do |p|
        p[:name] == oidc_identity.provider
      end

      return nil unless provider_config

      # For OIDC providers, fetch end_session_endpoint from discovery
      if provider_config[:strategy] == "openid_connect" && provider_config[:issuer].present?
        begin
          discovery_url = discovery_url_for(provider_config[:issuer])
          response = Faraday.get(discovery_url) do |req|
            req.options.timeout = 5
            req.options.open_timeout = 3
          end

          return nil unless response.success?

          discovery = JSON.parse(response.body)
          end_session_endpoint = discovery["end_session_endpoint"]

          return nil unless end_session_endpoint.present?

          # Build the logout URL with post_logout_redirect_uri
          post_logout_redirect = "#{request.base_url}/auth/logout/callback"
          params = {
            id_token_hint: id_token,
            post_logout_redirect_uri: post_logout_redirect
          }

          "#{end_session_endpoint}?#{params.to_query}"
        rescue Faraday::Error, JSON::ParserError, StandardError => e
          Rails.logger.warn("[SSO] Failed to fetch OIDC discovery for logout: #{e.message}")
          nil
        end
      else
        nil
      end
    end

    def discovery_url_for(issuer)
      if issuer.end_with?("/")
        "#{issuer}.well-known/openid-configuration"
      else
        "#{issuer}/.well-known/openid-configuration"
      end
    end
end
