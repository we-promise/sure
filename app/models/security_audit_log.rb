# frozen_string_literal: true

# Audit trail for security-sensitive account operations. Separate from
# SsoAuditLog (app/models/sso_audit_log.rb), which is specifically about SSO
# login/link/unlink events and has a `provider` column these events have no
# use for.
class SecurityAuditLog < ApplicationRecord
  belongs_to :user, optional: true

  # Non-deterministic: this column is never queried by value, only ever
  # displayed to an investigator, so there's no reason to give up the
  # stronger (non-deterministic) ciphertext for lookup capability we don't
  # need. Keeping the email out of `metadata` (plain jsonb) matters because
  # these rows deliberately survive the user's deletion (see the FK comment
  # in the migration) — a plaintext copy would otherwise outlive and bypass
  # the encryption boundary `User#email` is under.
  encrypts :user_email

  EVENT_TYPES = %w[
    api_key_created
    api_key_revoked
    mfa_enabled
    mfa_disabled
    password_changed
    webauthn_credential_added
    webauthn_credential_removed
  ].freeze

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :by_event, ->(event) { where(event_type: event) }

  class << self
    def log_api_key_created!(user:, api_key:, request:)
      create!(
        user: user,
        user_email: user.email,
        event_type: "api_key_created",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: { api_key_id: api_key.id, name: api_key.name, scopes: api_key.scopes }
      )
    end

    def log_api_key_revoked!(user:, api_key:, request:)
      create!(
        user: user,
        user_email: user.email,
        event_type: "api_key_revoked",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: { api_key_id: api_key.id, name: api_key.name }
      )
    end

    def log_mfa_enabled!(user:, request:)
      create!(
        user: user,
        user_email: user.email,
        event_type: "mfa_enabled",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500)
      )
    end

    def log_mfa_disabled!(user:, request:)
      create!(
        user: user,
        user_email: user.email,
        event_type: "mfa_disabled",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500)
      )
    end

    def log_webauthn_credential_added!(user:, credential:, request:)
      create!(
        user: user,
        user_email: user.email,
        event_type: "webauthn_credential_added",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: { credential_id: credential.id, nickname: credential.nickname }
      )
    end

    def log_webauthn_credential_removed!(user:, credential:, request:)
      create!(
        user: user,
        user_email: user.email,
        event_type: "webauthn_credential_removed",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: { credential_id: credential.id, nickname: credential.nickname }
      )
    end

    # actor is the user who performed the change when it wasn't the account
    # owner themselves (e.g. a super admin resetting another user's password
    # from Admin::UsersController). Self-service changes (PasswordsController,
    # PasswordResetsController) leave it nil.
    def log_password_changed!(user:, request:, actor: nil)
      metadata = {}
      metadata[:actor_user_id] = actor.id if actor && actor.id != user.id

      create!(
        user: user,
        user_email: user.email,
        event_type: "password_changed",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end
  end
end
