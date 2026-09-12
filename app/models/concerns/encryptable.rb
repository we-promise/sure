module Encryptable
  extend ActiveSupport::Concern

  class_methods do
    # Helper to detect if ActiveRecord Encryption is configured for this app.
    # This allows encryption to be optional - if not configured, sensitive fields
    # are stored in plaintext (useful for development or legacy deployments).
    #
    # Uses ready? (not explicitly_configured?) so self-hosted installs relying
    # on the documented SECRET_KEY_BASE auto-generation fallback are correctly
    # recognized as encrypted, instead of silently skipping every `encrypts`
    # declaration that guards on this method.
    def encryption_ready?
      ActiveRecordEncryptionConfig.ready?
    end
  end
end
