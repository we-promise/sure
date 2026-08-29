# frozen_string_literal: true

# Audit trail for security-sensitive account operations. Separate from
# SsoAuditLog (app/models/sso_audit_log.rb), which is specifically about SSO
# login/link/unlink events and has a `provider` column these events have no
# use for.
class SecurityAuditLog < ApplicationRecord
  belongs_to :user, optional: true

  EVENT_TYPES = %w[
    api_key_created
    api_key_revoked
    mfa_enabled
    mfa_disabled
    password_changed
  ].freeze

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :by_event, ->(event) { where(event_type: event) }

  class << self
    def log_api_key_created!(user:, api_key:, request:)
      create!(
        user: user,
        event_type: "api_key_created",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: identity_snapshot(user).merge(api_key_id: api_key.id, name: api_key.name, scopes: api_key.scopes)
      )
    end

    def log_api_key_revoked!(user:, api_key:, request:)
      create!(
        user: user,
        event_type: "api_key_revoked",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: identity_snapshot(user).merge(api_key_id: api_key.id, name: api_key.name)
      )
    end

    def log_mfa_enabled!(user:, request:)
      create!(
        user: user,
        event_type: "mfa_enabled",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: identity_snapshot(user)
      )
    end

    def log_mfa_disabled!(user:, request:)
      create!(
        user: user,
        event_type: "mfa_disabled",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: identity_snapshot(user)
      )
    end

    # actor is the user who performed the change when it wasn't the account
    # owner themselves (e.g. a super admin resetting another user's password
    # from Admin::UsersController). Self-service changes (PasswordsController,
    # PasswordResetsController) leave it nil.
    def log_password_changed!(user:, request:, actor: nil)
      metadata = identity_snapshot(user)
      metadata[:actor_user_id] = actor.id if actor && actor.id != user.id

      create!(
        user: user,
        event_type: "password_changed",
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end

    private

      # The user_id column is nullified (not cascaded) when the user is
      # deleted, so it alone can't identify who a row was about afterward.
      # Snapshotting the email into metadata keeps that identity legible to
      # an investigator even after the account is gone.
      def identity_snapshot(user)
        { user_email: user.email }
      end
  end
end
