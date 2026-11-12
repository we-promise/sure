# frozen_string_literal: true

# Warn self-hosted operators when ActiveRecord Encryption is NOT configured.
#
# This emits a clear startup warning so plaintext-at-rest is never silent.
require Rails.root.join("lib/active_record_encryption_config").to_s

Rails.application.config.after_initialize do
  if ActiveRecordEncryptionConfig.previous_keys_configured?
    Rails.logger.warn(<<~WARN)
      [SECURITY] Previous Active Record encryption keys are set
      (ACTIVE_RECORD_ENCRYPTION_PREVIOUS_*), so they are a previous encryption
      scheme. Set them only for the commands of a key rotation, not for the
      running app: while they are set, Rails writes deterministically
      encrypted values (emails, tokens, API keys) with the old key.
    WARN
  end

  app_mode = Rails.application.config.app_mode

  # Scoped to self-hosted only: this warning is about AR encryption not
  # being configured, which is only ever this app's own responsibility to
  # set up on a self-hosted install (managed instances are operated by the
  # Sure team with their own credential provisioning).
  if app_mode.self_hosted?
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
  end

  # Deliberately NOT nested inside the `if app_mode.self_hosted?` block
  # above (a prior version of this file gated the whole `after_initialize`
  # body on a single `next unless app_mode.self_hosted?`, which silently
  # suppressed this check in managed mode too - jjmata caught this on
  # #3221's version of this same file): using_known_compromised_secret_key_base?
  # is a fact about SECRET_KEY_BASE itself (session cookies, Setting's own
  # encryptor - see app/models/setting.rb), independent of whether
  # ActiveRecord Encryption is configured at all, where its keys come from,
  # or which app_mode this install runs in - a managed instance spun up
  # from compose.example.yml (e.g. for staging/POC) and never rotated is
  # just as exposed as a self-hosted one. Suppressing it whenever AR
  # encryption has explicit keys, or whenever the app isn't self-hosted,
  # would hide a real compromise of sessions/Settings just because AR
  # encryption itself isn't affected.
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
        Setting-stored values encrypted under the old one. Re-encrypt those
        with bin/rails "security:rotate_setting_secrets[0]", with the old
        value in the OLD_SECRET_KEY_BASE environment variable (see
        docs/hosting/encryption.md; keep it out of your shell history).
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
        unrecoverable. Rotate safely instead, with the app stopped (full
        procedure in docs/hosting/encryption.md): generate new keys with
        bin/rails db:encryption:init and set them as
        ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
        and ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT, then run
        bin/rails "security:backfill_encryption[100,0]" with this
        SECRET_KEY_BASE in #{ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV}
        for that command only, so existing data still decrypts and is
        re-encrypted under the new keys, deterministic columns included.
        When every model reports failed_count 0, start the app without that
        variable: while it is set, Rails writes deterministically encrypted
        values (emails, tokens, API keys) with the old key.
        Changing SECRET_KEY_BASE afterwards also changes the key for API keys
        and tokens saved in the settings (not covered by the previous scheme):
        re-encrypt them with bin/rails "security:rotate_setting_secrets[0]",
        with the old value in the OLD_SECRET_KEY_BASE environment variable.
      WARN
    end
  end
end
