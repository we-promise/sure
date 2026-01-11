# frozen_string_literal: true

class SsoAuditLog < ApplicationRecord
  belongs_to :user, optional: true

  # Event types for SSO audit logging
  EVENT_TYPES = %w[
    login
    login_failed
    logout
    logout_idp
    link
    unlink
    jit_account_created
  ].freeze

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :by_event, ->(event) { where(event_type: event) }

  class << self
    # Log a successful SSO login
    def log_login!(user:, provider:, request:, metadata: {})
      create!(
        user: user,
        event_type: "login",
        provider: provider,
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end

    # Log a failed SSO login attempt
    def log_login_failed!(provider:, request:, reason:, metadata: {})
      create!(
        user: nil,
        event_type: "login_failed",
        provider: provider,
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata.merge(reason: reason)
      )
    end

    # Log a logout (local only)
    def log_logout!(user:, request:, metadata: {})
      create!(
        user: user,
        event_type: "logout",
        provider: nil,
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end

    # Log a federated logout (to IdP)
    def log_logout_idp!(user:, provider:, request:, metadata: {})
      create!(
        user: user,
        event_type: "logout_idp",
        provider: provider,
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end

    # Log an account link (existing user links SSO identity)
    def log_link!(user:, provider:, request:, metadata: {})
      create!(
        user: user,
        event_type: "link",
        provider: provider,
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end

    # Log an account unlink (user disconnects SSO identity)
    def log_unlink!(user:, provider:, request:, metadata: {})
      create!(
        user: user,
        event_type: "unlink",
        provider: provider,
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end

    # Log JIT account creation via SSO
    def log_jit_account_created!(user:, provider:, request:, metadata: {})
      create!(
        user: user,
        event_type: "jit_account_created",
        provider: provider,
        ip_address: request.remote_ip,
        user_agent: request.user_agent&.truncate(500),
        metadata: metadata
      )
    end
  end
end
