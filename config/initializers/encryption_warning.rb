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
      installation's "encrypted" data is not actually protected.
      Do NOT simply set a new SECRET_KEY_BASE and run
      security:backfill_encryption: if any data was already encrypted under
      the compromised key, the backfill task cannot tell that ciphertext
      apart from real plaintext, will re-encrypt it under the new key on
      top of the old encryption, and the original data becomes
      unrecoverable. Rotate safely instead:
        1. Compute the OLD derived keys from your current SECRET_KEY_BASE
           (bin/rails runner 'puts Digest::SHA256.hexdigest("\#{Rails.application.secret_key_base}:primary_key")[0..63]'
           - repeat for :deterministic_key and :key_derivation_salt) and set
           them as ACTIVE_RECORD_ENCRYPTION_*_PREVIOUS so existing data still
           decrypts. Older Compose releases did not pass
           ACTIVE_RECORD_ENCRYPTION_* through to the container, so don't
           assume env vars alone reflect the keys actually used to write
           existing data - derive from SECRET_KEY_BASE unless you know
           otherwise.
        2. Generate new ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY (and friends)
           with bin/rails db:encryption:init and set those as the current
           (non-_PREVIOUS) values.
        3. Re-run bin/rails security:backfill_encryption to re-encrypt
           existing rows under the new keys.
        4. Separately, app/models/setting.rb encrypts its own fields
           (provider/API credentials) using a key derived directly from
           SECRET_KEY_BASE, NOT from these AR encryption keys - rotating
           SECRET_KEY_BASE also invalidates those without any warning or
           rotation path today. Expect saved Settings values to need
           re-entering after this rotation, and rotate SECRET_KEY_BASE
           itself only once you've confirmed that's acceptable (it also
           invalidates all sessions and signed cookies).
    WARN
  end
end
