module Encryptable
  extend ActiveSupport::Concern

  class_methods do
    # Helper to detect if ActiveRecord Encryption is configured for this app.
    # This allows encryption to be optional - if not configured, sensitive fields
    # are stored in plaintext (useful for development or legacy deployments).
    def encryption_ready?
      creds_ready = Rails.application.credentials.active_record_encryption.present?
      env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                  ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                  ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
      creds_ready || env_ready
    end
  end
end
