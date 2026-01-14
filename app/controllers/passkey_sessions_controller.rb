class PasskeySessionsController < ApplicationController
  skip_authentication

  layout "auth"

  def new
  end

  def options
    # For discoverable credentials, we don't need to specify allowCredentials
    # The browser will show all available passkeys for this RP
    options = WebAuthn::Credential.options_for_get(
      user_verification: "preferred"
    )

    session[:passkey_authentication_challenge] = options.challenge

    render json: options
  end

  def create
    credential_params = params[:credential]
    unless credential_params.is_a?(ActionController::Parameters) && credential_params[:id].present?
      render json: { error: "Invalid credential data" }, status: :unprocessable_entity
      return
    end

    webauthn_credential = WebAuthn::Credential.from_get(credential_params)

    # Find the passkey by credential ID
    passkey = Passkey.find_by_credential_id(webauthn_credential.raw_id)

    unless passkey
      render json: { error: t(".passkey_not_found") }, status: :unprocessable_entity
      return
    end

    user = passkey.user

    webauthn_credential.verify(
      session[:passkey_authentication_challenge],
      public_key: Base64.urlsafe_decode64(passkey.public_key),
      sign_count: passkey.sign_count
    )

    passkey.update_sign_count!(webauthn_credential.sign_count)

    session.delete(:passkey_authentication_challenge)

    if user.otp_required?
      session[:mfa_user_id] = user.id
      render json: { success: true, redirect_to: verify_mfa_path }
    else
      create_session_for(user)
      render json: { success: true, redirect_to: root_path }
    end
  rescue WebAuthn::Error => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end
end
