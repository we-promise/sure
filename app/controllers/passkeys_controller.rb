class PasskeysController < ApplicationController
  def new
    options = WebAuthn::Credential.options_for_create(
      user: {
        id: Current.user.id.to_s,
        name: Current.user.email,
        display_name: Current.user.display_name
      },
      # Decode the stored Base64URL external_ids to raw bytes for the exclude list
      exclude: Current.user.passkeys.pluck(:external_id).map { |id| Base64.urlsafe_decode64(id) },
      # Enable discoverable credentials (resident keys) for passwordless sign-in
      authenticator_selection: {
        resident_key: "preferred",
        user_verification: "preferred"
      }
    )

    session[:passkey_creation_challenge] = options.challenge

    render json: options.as_json
  end

  def create
    credential_params = params[:credential]
    unless credential_params.is_a?(ActionController::Parameters) && credential_params[:id].present?
      render json: { success: false, error: "Invalid credential data" }, status: :unprocessable_entity
      return
    end

    webauthn_credential = WebAuthn::Credential.from_create(credential_params)

    webauthn_credential.verify(session[:passkey_creation_challenge])

    passkey = Current.user.passkeys.create!(
      external_id: Base64.urlsafe_encode64(webauthn_credential.raw_id, padding: false),
      public_key: Base64.urlsafe_encode64(webauthn_credential.public_key, padding: false),
      label: params[:label].presence || default_passkey_label,
      sign_count: webauthn_credential.sign_count
    )

    session.delete(:passkey_creation_challenge)

    render json: { success: true, passkey: { id: passkey.id, label: passkey.label } }
  rescue WebAuthn::Error => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def update
    passkey = Current.user.passkeys.find(params[:id])
    passkey.update!(label: params[:label])

    respond_to do |format|
      format.html { redirect_to settings_security_path, notice: t(".success") }
      format.json { render json: { success: true, passkey: { id: passkey.id, label: passkey.label } } }
    end
  end

  def destroy
    passkey = Current.user.passkeys.find(params[:id])
    passkey.destroy!

    redirect_to settings_security_path, notice: t(".success")
  end

  private

    def default_passkey_label
      "Passkey #{Current.user.passkeys.count + 1}"
    end
end
