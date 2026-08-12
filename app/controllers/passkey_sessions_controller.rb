# frozen_string_literal: true

# Passwordless sign-in with a discoverable passkey ("usernameless" WebAuthn).
#
# The browser resolves which credential to use, so no email is submitted and
# nothing here can be probed for account enumeration. User verification is
# REQUIRED at assertion time, which makes a lone passkey two factors on its
# own (possession + biometric/PIN) — that is why this path deliberately skips
# the TOTP step in MfaController.
class PasskeySessionsController < ApplicationController
  include WebauthnRelyingParty

  skip_authentication only: %i[options create]

  def options
    return head :forbidden unless AuthConfig.passkey_login_enabled?

    request_options = webauthn_relying_party.options_for_authentication(
      user_verification: "required"
    )

    session[:passkey_login_challenge] = request_options.challenge

    render json: request_options
  end

  def create
    return head :forbidden unless AuthConfig.passkey_login_enabled?

    challenge = session.delete(:passkey_login_challenge)
    return render_invalid if challenge.blank?

    credential = WebAuthn::Credential.from_get(
      webauthn_credential_payload,
      relying_party: webauthn_relying_party
    )

    user = user_for(credential)
    return render_invalid unless user&.active?
    return render_invalid unless AuthConfig.local_login_allowed_for?(user)

    # Scoped to the user so an assertion can never pair one account's user
    # handle with another account's credential.
    stored_credential = user.webauthn_credentials.find_by(credential_id: credential.id)
    return render_invalid unless stored_credential

    stored_credential.with_lock do
      credential.verify(
        challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count,
        user_presence: true,
        user_verification: true
      )

      stored_credential.update!(
        sign_count: credential.sign_count,
        last_used_at: Time.current
      )
    end

    complete_sign_in(user)

    render json: { redirect_url: root_path }
  rescue WebAuthn::Error, ActionController::BadRequest, ActionController::ParameterMissing
    render_invalid
  end

  private
    def user_for(credential)
      # `presence` matters: `find_by(webauthn_id: nil)` would match every user
      # who never registered a credential.
      handle = credential.user_handle.presence
      return nil if handle.blank?

      User.find_by(webauthn_id: handle)
    end

    def complete_sign_in(user)
      # Drop any half-finished password + TOTP attempt from this browser.
      session.delete(:mfa_user_id)

      @session = create_session_for(user)
      flash[:notice] = t("invitations.accept_choice.joined_household") if accept_pending_invitation_for(user)
    end

    def render_invalid
      render json: { error: t("passkey_sessions.invalid_credential") }, status: :unprocessable_entity
    end
end
