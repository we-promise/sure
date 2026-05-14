module Encryptable
  extend ActiveSupport::Concern

  class_methods do
    # Helper to detect if ActiveRecord Encryption is configured for this app.
    # This allows encryption to be optional - if not configured, sensitive fields
    # are stored in plaintext (useful for development or legacy deployments).
    def encryption_ready?
      ActiveRecordEncryptionConfig.explicitly_configured?
    end
  end
end
