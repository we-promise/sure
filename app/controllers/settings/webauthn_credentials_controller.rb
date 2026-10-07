class Settings::WebauthnCredentialsController < ApplicationController
  include WebauthnRelyingParty

  layout "settings"

  before_action :ensure_mfa_enabled

  # Adding a passkey is confirmed with an MFA code; keep a stolen session from
  # guessing that code.
  rate_limit to: 10, within: 1.minute, by: -> { Current.user.id }, only: :create,
    with: -> { render json: { error: t("webauthn_credentials.rate_limited") }, status: :too_many_requests }

  def options
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

    case code_result
    when :accepted
      render json: { redirect_url: settings_security_path }
    when :replayed
      render json: { error: t("webauthn_credentials.code_already_used") }, status: :unprocessable_entity
    else
      render json: { error: t("webauthn_credentials.invalid_code") }, status: :unprocessable_entity
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

    def webauthn_credential_params
      params.fetch(:webauthn_credential, ActionController::Parameters.new).permit(:nickname, :code)
    end

    def credential_response_params
      params.fetch(:credential, ActionController::Parameters.new).permit(response: [ transports: [] ])
    end
end
