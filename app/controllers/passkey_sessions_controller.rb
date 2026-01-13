class PasskeySessionsController < ApplicationController
  skip_authentication

  layout "auth"

  def new
    @email = params[:email]
  end

  def options
    user = User.find_by(email: params[:email])

    unless user&.passkeys&.any?
      render json: { error: t(".no_passkeys") }, status: :unprocessable_entity
      return
    end

    options = WebAuthn::Credential.options_for_get(
      allow: user.passkeys.pluck(:external_id)
    )

    session[:passkey_authentication_challenge] = options.challenge
    session[:passkey_authentication_user_id] = user.id

    render json: options
  end

  def create
    user = User.find_by(id: session[:passkey_authentication_user_id])

    unless user
      render json: { error: t(".invalid_session") }, status: :unprocessable_entity
      return
    end

    credential_params = params[:credential]
    unless credential_params.is_a?(ActionController::Parameters) && credential_params[:id].present?
      render json: { error: "Invalid credential data" }, status: :unprocessable_entity
      return
    end

    webauthn_credential = WebAuthn::Credential.from_get(credential_params)

    passkey = user.passkeys.find_by(
      external_id: Base64.urlsafe_encode64(webauthn_credential.raw_id, padding: false)
    )

    unless passkey
      render json: { error: t(".passkey_not_found") }, status: :unprocessable_entity
      return
    end

    webauthn_credential.verify(
      session[:passkey_authentication_challenge],
      public_key: Base64.urlsafe_decode64(passkey.public_key),
      sign_count: passkey.sign_count
    )

    passkey.update_sign_count!(webauthn_credential.sign_count)

    session.delete(:passkey_authentication_challenge)
    session.delete(:passkey_authentication_user_id)

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
