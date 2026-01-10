class OidcAccountsController < ApplicationController
  skip_authentication only: [ :link, :create_link, :new_user, :create_user ]
  layout "auth"

  def link
    # Check if there's pending OIDC auth in session
    @pending_auth = session[:pending_oidc_auth]

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    @email = @pending_auth["email"]
    @user_exists = User.exists?(email: @email) if @email.present?

    # Determine whether we should offer JIT account creation for this
    # pending auth, based on JIT mode and allowed domains.
    @allow_account_creation = !AuthConfig.jit_link_only? && AuthConfig.allowed_oidc_domain?(@email)
  end

  def create_link
    @pending_auth = session[:pending_oidc_auth]

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    # Verify user's password to confirm identity
    user = User.authenticate_by(email: params[:email], password: params[:password])

    if user
      # Create the OIDC identity link
      oidc_identity = OidcIdentity.create_from_omniauth(
        build_auth_hash(@pending_auth),
        user
      )

      # Clear pending auth from session
      session.delete(:pending_oidc_auth)

      # Check if user has MFA enabled
      if user.otp_required?
        session[:mfa_user_id] = user.id
        redirect_to verify_mfa_path
      else
        @session = create_session_for(user)
        redirect_to root_path, notice: "Account successfully linked to #{@pending_auth['provider']}"
      end
    else
      @email = params[:email]
      @user_exists = User.exists?(email: @email) if @email.present?
      flash.now[:alert] = "Invalid email or password"
      render :link, status: :unprocessable_entity
    end
  end

  def new_user
    # Check if there's pending OIDC auth in session
    @pending_auth = session[:pending_oidc_auth]

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    # Pre-fill user details from OIDC provider
    @user = User.new(
      email: @pending_auth["email"],
      first_name: @pending_auth["first_name"],
      last_name: @pending_auth["last_name"]
    )
  end

  def create_user
    @pending_auth = session[:pending_oidc_auth]

    if @pending_auth.nil?
      redirect_to new_session_path, alert: "No pending OIDC authentication found"
      return
    end

    email = @pending_auth["email"]

    # Respect global JIT configuration: in link_only mode or when the email
    # domain is not allowed, block JIT account creation and send the user
    # back to the login page with a clear message.
    unless !AuthConfig.jit_link_only? && AuthConfig.allowed_oidc_domain?(email)
      redirect_to new_session_path, alert: "SSO account creation is disabled. Please contact an administrator."
      return
    end

    # Create SSO-only user without local password.
    # Security: JIT users should NOT have password_digest set to prevent
    # chained authentication attacks where SSO users gain local login access
    # via password reset.
    @user = User.new(
      email: email,
      first_name: @pending_auth["first_name"],
      last_name: @pending_auth["last_name"],
      skip_password_validation: true
    )

    # Create new family for this user
    @user.family = Family.new
    @user.role = :admin

    if @user.save
      # Create the OIDC (or other SSO) identity
      OidcIdentity.create_from_omniauth(
        build_auth_hash(@pending_auth),
        @user
      )

      # Clear pending auth from session
      session.delete(:pending_oidc_auth)

      # Create session and log them in
      @session = create_session_for(@user)
      redirect_to root_path, notice: "Welcome! Your account has been created."
    else
      render :new_user, status: :unprocessable_entity
    end
  end

  private

    # Convert pending auth hash to OmniAuth-like structure
    def build_auth_hash(pending_auth)
      OpenStruct.new(
        provider: pending_auth["provider"],
        uid: pending_auth["uid"],
        info: OpenStruct.new(pending_auth.slice("email", "name", "first_name", "last_name"))
      )
    end
end
