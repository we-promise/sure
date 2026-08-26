# frozen_string_literal: true

# Warn self-hosted operators when ActiveRecord Encryption is NOT configured.
#
# This emits a clear startup warning so plaintext-at-rest is never silent.
require Rails.root.join("lib/active_record_encryption_config").to_s

Rails.application.config.after_initialize do
  app_mode = Rails.application.config.app_mode
  next unless app_mode.self_hosted?

  if !ActiveRecordEncryptionConfig.ready?
    Rails.logger.warn(<<~WARN)
      [SECURITY] ActiveRecord Encryption is NOT configured. Sensitive data
      (API keys, provider/bank tokens, MFA secrets, and PII) are being stored
      UNENCRYPTED at rest. To enable encryption, set the following keys in your Rails credentials or environment variables:
        ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
        ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
        ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
      Generate a set with: bin/rails db:encryption:init
    WARN
  elsif ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?
    Rails.logger.warn(<<~WARN)
      [SECURITY] ActiveRecord Encryption keys were auto-derived from a
      SECRET_KEY_BASE value that was previously shipped as a working
      default in this project's example Docker Compose files. Anyone who
      knows that value can compute the same encryption keys, so this
      installation's "encrypted" data is not actually protected. Set your
      own SECRET_KEY_BASE (openssl rand -hex 64), then explicitly set
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY,
      and ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT (bin/rails db:encryption:init)
      and re-run bin/rails security:backfill_encryption to re-encrypt existing data
      under the new keys.
    WARN
  end
end
