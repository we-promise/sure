# frozen_string_literal: true

module WebauthnRelyingParty
  extend ActiveSupport::Concern

  private
    def webauthn_relying_party
      webauthn_config = Rails.application.config.x.webauthn

      WebAuthn::RelyingParty.new(
        name: "Sure",
        id: webauthn_config.rp_id,
        allowed_origins: webauthn_config.allowed_origins,
        # Accept consumer passkeys/security keys without attesting device vendor
        # identity; this keeps MFA registration broad for self-hosted users.
        verify_attestation_statement: false
      )
    end

    def webauthn_credential_payload
      payload = params.require(:credential)
      payload = JSON.parse(payload) if payload.is_a?(String)

      payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
      raise ActionController::BadRequest, "credential must be an object" unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError, TypeError, ArgumentError
      raise ActionController::BadRequest, "invalid credential payload"
    end
end
