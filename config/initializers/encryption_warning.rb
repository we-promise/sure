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
  end

  # Deliberately NOT chained as `elsif` onto the check above:
  # using_known_compromised_secret_key_base? is a fact about SECRET_KEY_BASE
  # itself (session cookies, Setting's own encryptor - see
  # app/models/setting.rb), independent of whether ActiveRecord Encryption
  # is configured at all or where its keys come from. Suppressing it
  # whenever AR encryption has explicit keys would hide a real compromise of
  # sessions/Settings just because AR encryption itself isn't affected.
  if ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?
    if ActiveRecordEncryptionConfig.explicitly_configured?
      Rails.logger.warn(<<~WARN)
        [SECURITY] SECRET_KEY_BASE is set to a value that was previously
        shipped as a working default in this project's example Docker
        Compose files. Anyone who knows that value can forge or decrypt
        Rails session cookies, and can decrypt any value stored via Setting
        (AI/market-data provider API keys, etc.), which derives its own
        encryption key directly from SECRET_KEY_BASE - independently of
        ActiveRecord Encryption. Your ActiveRecord Encryption keys are
        explicitly configured and are NOT derived from SECRET_KEY_BASE, so
        they are unaffected by this. Rotate SECRET_KEY_BASE to a unique
        value regardless. Note this invalidates existing sessions and any
        Setting-stored values encrypted under the old one, which will need
        to be re-entered - there is currently no automated migration path
        for those two, only for ActiveRecord Encryption's own keys (see
        bin/rails db:encryption:init).
      WARN
    else
      Rails.logger.warn(<<~WARN)
        [SECURITY] ActiveRecord Encryption keys were auto-derived from a
        SECRET_KEY_BASE value that was previously shipped as a working
        default in this project's example Docker Compose files. Anyone who
        knows that value can compute the same encryption keys, so this
        installation's "encrypted" data is not actually protected. The same
        value also signs/encrypts Rails session cookies and Setting's own
        encrypted values (AI/market-data provider API keys, etc.), which
        are compromised regardless of ActiveRecord Encryption.
        Do NOT simply set a new SECRET_KEY_BASE and run
        security:backfill_encryption: if any data was already encrypted under
        the compromised key, the backfill task cannot tell that ciphertext
        apart from real plaintext, will re-encrypt it under the new key on
        top of the old encryption, and the original data becomes
        unrecoverable. Rotate safely instead: keep
        ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY (and friends) derived from this
        SECRET_KEY_BASE configured as a `previous` encryption scheme
        (https://guides.rubyonrails.org/active_record_encryption.html#key-rotation)
        so existing data still decrypts, generate new keys with
        bin/rails db:encryption:init as the current scheme, then re-run
        bin/rails security:backfill_encryption to re-encrypt under the new
        keys. This only migrates ActiveRecord Encryption - Setting-stored
        values and existing sessions are not covered and must be rotated /
        re-entered separately.
      WARN
    end
  end
end
