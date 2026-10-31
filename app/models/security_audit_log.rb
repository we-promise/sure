# frozen_string_literal: true

# Audit trail for security-sensitive account operations. Separate from
# SsoAuditLog (app/models/sso_audit_log.rb), which is specifically about SSO
# login/link/unlink events and has a `provider` column these events have no
# use for.
#
# Scope: API key create/revoke, MFA enable/disable, password changes and
# WebAuthn credential add/remove. Deliberately not (yet) covering email
# change, session revocation, backup-code consumption/regeneration or role
# elevation (the latter is Rails.logger-only in Admin::UsersController) —
# left out to keep this PR reviewable, not because they're lower value.
#
# Currently console-only: nothing in app/views or the API reads this table
# (same as SsoAuditLog). There's no retention/pruning job — rows are kept
# indefinitely, including after the user they're about is deleted, which is
# deliberate (see the FK comment in the migration) but still an open
# decision for a future PR rather than a default to leave unexamined.
class SecurityAuditLog < ApplicationRecord
  include Encryptable

  belongs_to :user, optional: true

  # Non-deterministic: none of these columns are ever queried by value, only
  # ever displayed to an investigator, so there's no reason to give up the
  # stronger (non-deterministic) ciphertext for lookup capability we don't
  # need. Keeping them out of `metadata` (plain jsonb) matters because these
  # rows deliberately survive the user's deletion (see the FK comment in the
  # migration) — plaintext copies would otherwise outlive and bypass the
  # encryption boundary `User#email` and `Session#user_agent` are under, and
  # the IP/user agent would otherwise be a GDPR-erasure gap for an account
  # that's supposed to be gone. Guarded like every other encrypted column in
  # the app (`User#email`, `Session#user_agent`): if encryption isn't
  # explicitly configured, these stay plaintext rather than silently
  # encrypting under a `SECRET_KEY_BASE`-derived key that later breaks when
  # the operator sets explicit keys (see `encryption_warning.rb`).
  if encryption_ready?
    encrypts :user_email
    encrypts :ip_address
    encrypts :user_agent
  end

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
    # actor is the user who performed the change when it wasn't the account
    # owner themselves — an admin resetting another user's password from
    # Admin::UsersController, or a super admin impersonating the account
    # owner. Callers should pass `Current.true_user`, not `Current.user`:
    # `Current.user` resolves to the impersonated user during impersonation,
    # which would attribute the actor's own action to their victim. Omitted
    # from metadata whenever actor == user, so genuinely self-service changes
    # don't carry a redundant actor_user_id.
    def log_api_key_created!(user:, api_key:, request:, actor: nil)
      create!(
        user: user,
        user_email: user.email,
        event_type: "api_key_created",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: actor_metadata(actor, user, api_key_id: api_key.id, name: api_key.name, scopes: api_key.scopes)
      )
    end

    def log_api_key_revoked!(user:, api_key:, request:, actor: nil)
      create!(
        user: user,
        user_email: user.email,
        event_type: "api_key_revoked",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: actor_metadata(actor, user, api_key_id: api_key.id, name: api_key.name)
      )
    end

    def log_mfa_enabled!(user:, request:, actor: nil)
      create!(
        user: user,
        user_email: user.email,
        event_type: "mfa_enabled",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: actor_metadata(actor, user)
      )
    end

    def log_mfa_disabled!(user:, request:, actor: nil)
      create!(
        user: user,
        user_email: user.email,
        event_type: "mfa_disabled",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: actor_metadata(actor, user)
      )
    end

    def log_webauthn_credential_added!(user:, credential:, request:, actor: nil)
      create!(
        user: user,
        user_email: user.email,
        event_type: "webauthn_credential_added",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: actor_metadata(actor, user, credential_id: credential.id, nickname: credential.nickname)
      )
    end

    def log_webauthn_credential_removed!(user:, credential:, request:, actor: nil)
      create!(
        user: user,
        user_email: user.email,
        event_type: "webauthn_credential_removed",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: actor_metadata(actor, user, credential_id: credential.id, nickname: credential.nickname)
      )
    end

    def log_password_changed!(user:, request:, actor: nil)
      create!(
        user: user,
        user_email: user.email,
        event_type: "password_changed",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: actor_metadata(actor, user)
      )
    end

    private

      def actor_metadata(actor, user, extra = {})
        metadata = extra.dup
        metadata[:actor_user_id] = actor.id if actor && actor.id != user.id
        metadata
      end
  end
end
