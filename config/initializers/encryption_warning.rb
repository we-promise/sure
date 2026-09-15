# frozen_string_literal: true

# Warn self-hosted operators when ActiveRecord Encryption is NOT configured.
#
# This emits a clear startup warning so plaintext-at-rest is never silent.
require Rails.root.join("lib/active_record_encryption_config").to_s

Rails.application.config.after_initialize do
  app_mode = Rails.application.config.app_mode

  # Scoped to self-hosted only: this warning is about AR encryption not
  # being configured at all, which is only ever this app's own
  # responsibility to set up on a self-hosted install (managed instances are
  # operated by the Sure team with their own credential provisioning).
  if app_mode.self_hosted? && !ActiveRecordEncryptionConfig.ready?
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

  # Deliberately NOT gated on app_mode.self_hosted? (a prior version of this
  # file nested the whole after_initialize body under a single `next unless
  # app_mode.self_hosted?`, which silently suppressed this check in managed
  # mode too): using_known_compromised_secret_key_base? is a fact about
  # SECRET_KEY_BASE itself (session cookies, Setting's own encryptor - see
  # app/models/setting.rb), independent of whether ActiveRecord Encryption
  # is configured at all, where its keys come from, or which app_mode this
  # install runs in - a managed instance spun up from compose.example.yml
  # (e.g. for staging/POC) and never rotated is just as exposed as a
  # self-hosted one.
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
          4. This only migrates ActiveRecord Encryption - Setting-stored
             values and existing sessions are not covered and must be
             rotated / re-entered separately, same as the explicitly-
             configured case above.
      WARN
    end
  end
end
