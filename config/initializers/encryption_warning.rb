# frozen_string_literal: true

# Warn self-hosted operators when ActiveRecord Encryption is NOT configured.
#
# This emits a clear startup warning so plaintext-at-rest is never silent.
require Rails.root.join("lib/active_record_encryption_config").to_s

Rails.application.config.after_initialize do
  if ENV[ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV].present?
    Rails.logger.warn(<<~WARN)
      [SECURITY] #{ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV} is set, so the
      keys derived from that old SECRET_KEY_BASE are a previous encryption scheme.
      Set it only for the commands of a key rotation, not for the running app:
      while it is set, Rails writes deterministically encrypted values (emails,
      tokens, API keys) with the old key.
    WARN
  end

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
      installation's "encrypted" data is not actually protected.
      Do NOT simply set a new SECRET_KEY_BASE and run
      security:backfill_encryption: if any data was already encrypted under
      the compromised key, the backfill task cannot tell that ciphertext
      apart from real plaintext, will re-encrypt it under the new key on
      top of the old encryption, and the original data becomes
      unrecoverable. Rotate safely instead, with the app stopped: generate
      new keys with bin/rails db:encryption:init and set them as
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      and ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT, then run
      bin/rails "security:backfill_encryption[100,0]" with this
      SECRET_KEY_BASE in #{ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV}
      for that command only, so existing data still decrypts and is
      re-encrypted under the new keys (see the Docker hosting guide). When
      every model reports failed_count 0, start the app without that
      variable: while it is set, Rails writes deterministically encrypted
      values (emails, tokens, API keys) with the old key.
      Changing SECRET_KEY_BASE afterwards also changes the key for API keys
      and tokens saved in the settings (not covered by the previous scheme):
      re-encrypt them with bin/rails "security:rotate_setting_secrets[0]",
      with the old value in the OLD_SECRET_KEY_BASE environment variable
      (see the Docker hosting guide; keep it out of your shell history).
    WARN
  end
end
