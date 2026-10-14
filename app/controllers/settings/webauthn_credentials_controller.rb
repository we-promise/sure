class Settings::WebauthnCredentialsController < ApplicationController
  include WebauthnRelyingParty

  layout "settings"

  before_action :ensure_mfa_enabled

  # Adding a passkey is confirmed with an MFA code; keep a stolen session from
  # guessing that code. Both steps check it, so each gets its own counter:
  # guessing through either one alone stays at 10 a minute.
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.id }, only: :options, name: "code-check",
    with: -> { render json: { error: t("webauthn_credentials.rate_limited") }, status: :too_many_requests }
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.id }, only: :create, name: "code-spend",
    with: -> { render json: { error: t("webauthn_credentials.rate_limited") }, status: :too_many_requests }

  def options
    # Refuse a bad code before the browser runs its ceremony; otherwise the
    # authenticator keeps a discoverable passkey the server never saves.
    code_status = Current.user.otp_code_status(webauthn_credential_params[:code])
    return render_code_error(code_status) unless code_status == :accepted

    Current.user.ensure_webauthn_id!

    registration_options = webauthn_relying_party.options_for_registration(
      user: {
        id: Current.user.webauthn_id,
        name: Current.user.email,
        display_name: Current.user.display_name
      },
      exclude: Current.user.webauthn_credentials.pluck(:credential_id),
      # `resident_key: "preferred"` asks for a discoverable credential so the
      # key can also be used for passwordless sign-in. "preferred" rather than
      # "required" so authenticators without free resident-key slots (older
      # security keys) can still register as a second factor. User verification
      # stays "preferred" here for the same reason and is enforced as
      # "required" on the passwordless sign-in ceremony instead.
      authenticator_selection: { resident_key: "preferred", user_verification: "preferred" },
      attestation: "none"
    )

    session[:webauthn_registration_challenge] = registration_options.challenge

    render json: registration_options
  end

  def create
    challenge = session.delete(:webauthn_registration_challenge)

    unless challenge.present?
      return render json: { error: t("webauthn_credentials.failure") }, status: :unprocessable_entity
    end

    credential = webauthn_relying_party.verify_registration(
      webauthn_credential_payload,
      challenge,
      user_presence: true
    )

    # A passkey is a lasting second factor and also a passwordless sign-in, so
    # adding one must prove more than the session cookie. The code is spent in
    # the same transaction as the save, so a registration that fails (or a
    # cancelled browser prompt) never uses up a single-use code.
    code_result = nil
    Current.user.transaction do
      code_result = Current.user.verify_otp(webauthn_credential_params[:code])
      raise ActiveRecord::Rollback unless code_result == :accepted

      Current.user.webauthn_credentials.create!(
        nickname: webauthn_credential_name,
        credential_id: credential.id,
        public_key: credential.public_key,
        sign_count: credential.sign_count,
        transports: webauthn_credential_transports
      )
    end

    if code_result == :accepted
      render json: { redirect_url: settings_security_path }
    else
      render_code_error(code_result)
    end
  rescue WebAuthn::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActionController::BadRequest, ActionController::ParameterMissing
    render json: { error: t("webauthn_credentials.failure") }, status: :unprocessable_entity
  end

  def destroy
    Current.user.webauthn_credentials.find(params[:id]).destroy!
    redirect_to settings_security_path, notice: t("webauthn_credentials.success")
  end

  private
    def ensure_mfa_enabled
      return if Current.user.otp_required?

      respond_to do |format|
        format.html { redirect_to settings_security_path, alert: t("webauthn_credentials.mfa_required") }
        format.json { render json: { error: t("webauthn_credentials.mfa_required") }, status: :forbidden }
      end
    end

    def webauthn_credential_name
      webauthn_credential_params[:nickname]
    end

    def webauthn_credential_transports
      Array(credential_response_params.dig(:response, :transports)).compact_blank
    end

    def render_code_error(code_status)
      key = code_status == :replayed ? "webauthn_credentials.code_already_used" : "webauthn_credentials.invalid_code"
      render json: { error: t(key) }, status: :unprocessable_entity
    end

    def webauthn_credential_params
      params.fetch(:webauthn_credential, ActionController::Parameters.new).permit(:nickname, :code)
    end

    def credential_response_params
      params.fetch(:credential, ActionController::Parameters.new).permit(response: [ transports: [] ])
    end
end
