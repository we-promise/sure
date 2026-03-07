class SessionsController < ApplicationController
  extend SslConfigurable

  before_action :set_session, only: :destroy
  skip_authentication only: %i[index new create openid_connect failure post_logout mobile_sso_start]

  layout "auth"

  # Handle GET /sessions (usually from browser back button)
  def index
    redirect_to new_session_path
  end

  def new
    store_pending_invitation_if_valid
    # Clear any stale mobile SSO session flag from an abandoned mobile flow
    session.delete(:mobile_sso)

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
    # Clear any stale mobile SSO session flag from an abandoned mobile flow
    session.delete(:mobile_sso)

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
        flash[:notice] = t("invitations.accept_choice.joined_household") if accept_pending_invitation_for(user)
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
      mobile_sso_redirect(error: "invalid_provider", message: "SSO provider not configured")
      return
    end

    device_params = params.permit(:device_id, :device_name, :device_type, :os_version, :app_version)
    unless device_params[:device_id].present? && device_params[:device_name].present? && device_params[:device_type].present?
      mobile_sso_redirect(error: "missing_device_info", message: "Device information is required")
      return
    end

    session[:mobile_sso] = {
      device_id: device_params[:device_id],
      device_name: device_params[:device_name],
      device_type: device_params[:device_type],
      os_version: device_params[:os_version],
      app_version: device_params[:app_version]
    }

    # Render auto-submitting form to POST to OmniAuth (required by omniauth-rails_csrf_protection)
    @provider = provider
    render layout: false
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
          mobile_sso_redirect(error: "mfa_not_supported", message: "MFA users should sign in with email and password")
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
        flash[:notice] = t("invitations.accept_choice.joined_household") if accept_pending_invitation_for(user)
        redirect_to root_path
      end
    else
      # Mobile SSO with no linked identity - redirect back with error
      if session[:mobile_sso].present?
        session.delete(:mobile_sso)
        mobile_sso_redirect(error: "account_not_linked", message: "Please link your Google account from the web app first")
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
      mobile_sso_redirect(error: sanitized_reason, message: "SSO authentication failed")
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

      unless device_info.present?
        mobile_sso_redirect(error: "missing_session", message: "Mobile SSO session expired")
        return
      end

      device = MobileDevice.upsert_device!(user, device_info.symbolize_keys)
      token_response = device.issue_token!

      # Store tokens behind a one-time authorization code instead of passing in URL
      authorization_code = SecureRandom.urlsafe_base64(32)
      Rails.cache.write(
        "mobile_sso:#{authorization_code}",
        token_response.merge(
          user_id: user.id,
          user_email: user.email,
          user_first_name: user.first_name,
          user_last_name: user.last_name,
          user_ui_layout: user.ui_layout,
          user_ai_enabled: user.ai_enabled?
        ),
        expires_in: 5.minutes
      )

      mobile_sso_redirect(code: authorization_code)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Mobile SSO] Device save failed: #{e.record.errors.full_messages.join(', ')}")
      mobile_sso_redirect(error: "device_error", message: "Unable to register device")
    end

    def mobile_sso_redirect(params = {})
      redirect_to "sureapp://oauth/callback?#{params.to_query}", allow_other_host: true
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
          response = Faraday.new(ssl: self.class.faraday_ssl_options).get(discovery_url) do |req|
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
