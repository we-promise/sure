# frozen_string_literal: true

module ActiveRecordEncryptionConfig
  ENV_KEYS = %w[
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  ].freeze

  # SECRET_KEY_BASE values ever shipped as a working default in
  # compose.example.yml / compose.example.ai.yml. Self-hosted installs that
  # deployed from one of those files without overriding it are running with
  # a publicly known secret. Since the auto-derived encryption keys
  # (config/initializers/active_record_encryption.rb) are a deterministic
  # function of SECRET_KEY_BASE, anyone with this value can compute the same
  # encryption keys, so `ready?` alone is not a meaningful signal of safety
  # for these installs even though it makes `runtime_configured?` true.
  KNOWN_COMPROMISED_SECRET_KEY_BASES = %w[
    a7523c3d0ae56415046ad8abae168d71074a79534a7062258f8d1d51ac2f76d3c3bc86d86b6b0b307df30d9a6a90a2066a3fa9e67c5e6f374dbd7dd4e0778e13
  ].freeze

  CONFIG_KEYS = %i[
    primary_key
    deterministic_key
    key_derivation_salt
  ].freeze

  # Bump this whenever a model/field is added to the coverage of
  # `bin/rails security:backfill_encryption` (lib/tasks/security_backfill.rake).
  # `backfill_completed?` compares an install's stored
  # Setting.encryption_backfill_completed_version against this value, so
  # bumping it correctly puts installs that completed a backfill under an
  # older, narrower version back into "not complete" until they re-run the
  # task - otherwise the legacy-plaintext fallback would get disabled for
  # models the install's last backfill never actually covered.
  CURRENT_BACKFILL_VERSION = 2

  # Single source of truth for which models/fields security:backfill_encryption
  # covers, keyed by the same symbol the task's `results` hash uses. Model
  # names are strings (not bare constants) and resolved via constantize only
  # from the task itself (after full Rails boot, via its :environment
  # dependency) - this file is `require`d from config/initializers/
  # active_record_encryption.rb, before autoloading is available, so a bare
  # constant reference here would raise NameError at boot.
  #
  # test/lib/tasks/security_backfill_test.rb asserts this stays in exact sync
  # with each model's real `encrypts` declarations, so a future field added
  # to a model's `encrypts` list without a matching manifest update (the
  # SnaptradeAccount#raw_balances_payload gap, previously) fails CI instead
  # of silently shipping a field the backfill - and thus the legacy-plaintext
  # fallback gating - never actually covers. Bump CURRENT_BACKFILL_VERSION
  # whenever this changes. Session is deliberately excluded: its backfill
  # (lib/tasks/security_backfill.rake#backfill_sessions) also hashes
  # ip_address into ip_address_digest, which isn't a 1:1 encrypted copy of an
  # existing field the way every entry below is.
  BACKFILL_MANIFEST = {
    users: [ "User", %i[otp_secret email unconfirmed_email first_name last_name] ],
    invitations: [ "Invitation", %i[token email] ],
    invite_codes: [ "InviteCode", %i[token] ],
    mobile_devices: [ "MobileDevice", %i[device_id] ],
    plaid_items: [ "PlaidItem", %i[access_token raw_payload raw_institution_payload] ],
    simplefin_items: [ "SimplefinItem", %i[access_url raw_payload raw_institution_payload] ],
    lunchflow_items: [ "LunchflowItem", %i[api_key raw_payload raw_institution_payload] ],
    enable_banking_items: [ "EnableBankingItem", %i[client_certificate session_id raw_payload raw_institution_payload] ],
    akahu_items: [ "AkahuItem", %i[app_token user_token raw_payload raw_institution_payload] ],
    binance_items: [ "BinanceItem", %i[api_key api_secret raw_payload] ],
    brex_items: [ "BrexItem", %i[token raw_payload raw_institution_payload] ],
    coinbase_items: [ "CoinbaseItem", %i[api_key api_secret raw_payload raw_institution_payload] ],
    coinstats_items: [ "CoinstatsItem", %i[api_key raw_payload raw_institution_payload] ],
    ibkr_items: [ "IbkrItem", %i[query_id token raw_payload] ],
    indexa_capital_items: [ "IndexaCapitalItem", %i[password api_token username document raw_payload raw_institution_payload] ],
    kraken_items: [ "KrakenItem", %i[api_key api_secret raw_payload] ],
    mercury_items: [ "MercuryItem", %i[token raw_payload raw_institution_payload] ],
    onchain_wallet_items: [ "OnchainWalletItem", %i[etherscan_api_key] ],
    questrade_items: [ "QuestradeItem", %i[refresh_token raw_payload raw_institution_payload] ],
    redbark_items: [ "RedbarkItem", %i[api_key raw_payload raw_institution_payload] ],
    snaptrade_items: [ "SnaptradeItem", %i[client_id consumer_key snaptrade_user_secret oauth_access_token oauth_refresh_token raw_payload raw_institution_payload] ],
    sophtron_items: [ "SophtronItem", %i[user_id access_key raw_payload raw_institution_payload raw_customer_payload raw_job_payload] ],
    trading212_items: [ "Trading212Item", %i[api_key api_secret raw_instruments_payload] ],
    up_items: [ "UpItem", %i[access_token raw_payload raw_institution_payload] ],
    wise_items: [ "WiseItem", %i[token raw_payload sca_private_key] ],
    plaid_accounts: [ "PlaidAccount", %i[raw_payload raw_transactions_payload raw_holdings_payload raw_liabilities_payload] ],
    simplefin_accounts: [ "SimplefinAccount", %i[raw_payload raw_transactions_payload raw_holdings_payload] ],
    lunchflow_accounts: [ "LunchflowAccount", %i[raw_payload raw_transactions_payload] ],
    enable_banking_accounts: [ "EnableBankingAccount", %i[raw_payload raw_transactions_payload] ],
    snaptrade_accounts: [ "SnaptradeAccount", %i[raw_payload raw_transactions_payload raw_holdings_payload raw_activities_payload raw_balances_payload] ],
    coinbase_accounts: [ "CoinbaseAccount", %i[raw_payload raw_transactions_payload] ],
    coinstats_accounts: [ "CoinstatsAccount", %i[raw_payload raw_transactions_payload] ],
    mercury_accounts: [ "MercuryAccount", %i[raw_payload raw_transactions_payload] ],
    akahu_accounts: [ "AkahuAccount", %i[raw_payload raw_transactions_payload] ],
    binance_accounts: [ "BinanceAccount", %i[raw_payload raw_transactions_payload] ],
    brex_accounts: [ "BrexAccount", %i[raw_payload raw_transactions_payload] ],
    ibkr_accounts: [ "IbkrAccount", %i[raw_holdings_payload raw_activities_payload raw_cash_report_payload raw_equity_summary_payload] ],
    indexa_capital_accounts: [ "IndexaCapitalAccount", %i[raw_payload raw_holdings_payload raw_activities_payload] ],
    kraken_accounts: [ "KrakenAccount", %i[raw_payload raw_transactions_payload] ],
    onchain_wallet_accounts: [ "OnchainWalletAccount", %i[raw_payload raw_movements_payload] ],
    questrade_accounts: [ "QuestradeAccount", %i[raw_payload raw_holdings_payload raw_activities_payload raw_balances_payload] ],
    redbark_accounts: [ "RedbarkAccount", %i[raw_payload raw_transactions_payload] ],
    sophtron_accounts: [ "SophtronAccount", %i[raw_payload raw_transactions_payload] ],
    trading212_accounts: [ "Trading212Account", %i[raw_positions_payload raw_orders_payload raw_dividends_payload raw_transactions_payload] ],
    up_accounts: [ "UpAccount", %i[raw_payload raw_transactions_payload] ],
    wise_accounts: [ "WiseAccount", %i[raw_payload raw_transactions_payload] ],
    api_keys: [ "ApiKey", %i[display_key] ],
    sso_providers: [ "SsoProvider", %i[client_secret] ],
    sso_identity_blocks: [ "SsoIdentityBlock", %i[identity_label] ]
  }.freeze

  module_function

  def complete_env?(env = ENV)
    ENV_KEYS.all? { |key| env_value_present?(env, key) }
  end

  def partial_env?(env = ENV)
    present_count = ENV_KEYS.count { |key| env_value_present?(env, key) }
    present_count.positive? && present_count < ENV_KEYS.count
  end

  def missing_env_keys(env = ENV)
    ENV_KEYS.reject { |key| env_value_present?(env, key) }
  end

  def partial_env_message(env = ENV)
    "Active Record encryption environment variables are partially configured. Missing: #{missing_env_keys(env).join(', ')}"
  end

  def credentials_configured?(credentials = Rails.application.credentials)
    config = credentials.active_record_encryption
    return false unless config.present?

    CONFIG_KEYS.all? { |key| config.public_send(key).present? }
  rescue NoMethodError
    false
  end

  # Unlike partial_env? (ENV vars), a present-but-incomplete Rails credentials
  # block does NOT fall through to auto-generation from SECRET_KEY_BASE - see
  # config/initializers/active_record_encryption.rb's `elsif ... &&
  # !Rails.application.credentials.active_record_encryption.present?` guard.
  # Left unchecked this silently disables encryption entirely (ready? / thus
  # every model's `encrypts` declaration goes false) instead of failing loudly
  # like the equivalent partial-ENV case does.
  #
  # Deliberately NOT the same shape as partial_env? (which requires at least
  # one key present): once the credentials block itself exists at all - even
  # with every individual key blank, e.g. `primary_key: ""` - that's already
  # a configuration mistake worth failing loudly on, unlike ENV vars being
  # entirely absent (a normal, unconfigured state that falls through to
  # other paths). CodeRabbit caught this: an all-blank block used to slip
  # through as present_count == 0, silently skipping both the raise and
  # self-hosted auto-generation (config.application.rb's `.present?` check
  # on the block already treats it as configured either way).
  def partial_credentials?(credentials = Rails.application.credentials)
    config = credentials.active_record_encryption
    return false unless config.present?

    !CONFIG_KEYS.all? { |key| config.public_send(key).present? }
  rescue NoMethodError
    false
  end

  def missing_credential_keys(credentials = Rails.application.credentials)
    config = credentials.active_record_encryption
    return CONFIG_KEYS.dup unless config.present?

    CONFIG_KEYS.reject { |key| config.public_send(key).present? }
  rescue NoMethodError
    CONFIG_KEYS.dup
  end

  def partial_credentials_message(credentials = Rails.application.credentials)
    "Active Record encryption Rails credentials are partially configured. Missing: #{missing_credential_keys(credentials).join(', ')}"
  end

  def runtime_configured?(config = Rails.application.config.active_record.encryption)
    CONFIG_KEYS.all? { |key| config.public_send(key).present? }
  rescue NoMethodError
    false
  end

  # Applies a resolved set of AR encryption keys to both the Rails config
  # object (for anything that reads it directly, e.g. runtime_configured?)
  # AND, if it's already been initialized, the live ActiveRecord::Encryption
  # engine config - mirroring the same belt-and-suspenders pattern this file
  # documents for support_unencrypted_data/extend_queries in config/
  # initializers/active_record_encryption.rb. Necessary because touching
  # ActiveRecord::Base.connection (as backfill_completed? does, earlier in
  # that same initializer) fires AR's one-time on_load(:active_record_
  # encryption_configuration) snapshot into ActiveRecord::Encryption.config
  # before these keys are known - Rails.application.config.active_record.
  # encryption.* alone is therefore insufficient; the engine itself needs
  # patching directly regardless of when that snapshot fired.
  def apply_keys!(primary_key:, deterministic_key:, key_derivation_salt:, config: Rails.application.config.active_record.encryption)
    config.primary_key = primary_key
    config.deterministic_key = deterministic_key
    config.key_derivation_salt = key_derivation_salt

    return unless defined?(ActiveRecord::Encryption)

    ActiveRecord::Encryption.config.primary_key = primary_key
    ActiveRecord::Encryption.config.deterministic_key = deterministic_key
    ActiveRecord::Encryption.config.key_derivation_salt = key_derivation_salt
  end

  def explicitly_configured?
    complete_env? || credentials_configured?
  end

  def ready?
    explicitly_configured? || runtime_configured?
  end

  # Deliberately independent of explicitly_configured?/ready?: this is a fact
  # about SECRET_KEY_BASE itself, not about whether Active Record Encryption's
  # own keys happen to be derived from it. Explicit AR keys only mean AR
  # encryption isn't affected - SECRET_KEY_BASE also signs/encrypts Rails
  # session cookies and is the sole key source for Setting's own encryptor
  # (app/models/setting.rb's setting_encryptor), independently of AR
  # encryption config. A previous version of this method returned false
  # whenever explicitly_configured? was true, which suppressed the warning
  # in config/initializers/encryption_warning.rb entirely for installs with
  # explicit AR keys - even though their sessions and Setting-encrypted
  # provider/AI API keys remained trivially crackable by anyone who knows
  # this public compromised value. See ActiveRecordEncryptionConfig#ready?
  # for the (separate) question of whether AR encryption itself is affected.
  def using_known_compromised_secret_key_base?(secret_key_base = Rails.application.secret_key_base)
    KNOWN_COMPROMISED_SECRET_KEY_BASES.include?(secret_key_base)
  rescue NoMethodError
    false
  end

  def env_value_present?(env, key)
    env[key].present?
  end

  # Whether `bin/rails security:backfill_encryption` has completed, cleanly,
  # against the current CURRENT_BACKFILL_VERSION's model/field coverage.
  #
  # Checked at boot in config/initializers/active_record_encryption.rb via a
  # PLAIN (non-deferred) call: ActiveRecord's own "active_record_encryption.
  # configuration" railtie initializer reads
  # Rails.application.config.active_record.encryption.* into the actual
  # ActiveRecord::Encryption.config object once, synchronously, in between
  # config/initializers running and Rails.application.config.after_initialize
  # firing - so setting support_unencrypted_data/extend_queries from inside
  # after_initialize (or any other deferred hook) is silently too late and
  # has no effect on real encryption behavior (verified empirically; this
  # method must stay callable synchronously at initializer time).
  #
  # That timing rules out using the `Setting` model directly: Setting is an
  # autoloaded app/* constant, and Rails autoloading isn't available yet
  # while config/initializers/*.rb are still being evaluated (referencing
  # any app/models class there raises `NameError: uninitialized constant`,
  # unconditionally - not just when the DB/table is missing). So this reads
  # the same `settings` table RailsSettings::Base uses directly via SQL,
  # sidestepping autoloading entirely while keeping the synchronous timing
  # `active_record_encryption.rb` depends on.
  #
  # This also runs before the backfill task can possibly have run on a fresh
  # install - and before the `settings` table is guaranteed to exist at all
  # (first `db:create`, asset precompile without a DB, etc). `false` is the
  # safe default in every one of those cases: it keeps the legacy-plaintext
  # fallback enabled, matching this app's pre-gating behavior, rather than
  # risking ActiveRecord::Encryption::Errors::Decryption on boot.
  def backfill_completed?(required_version: CURRENT_BACKFILL_VERSION)
    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT value FROM settings WHERE var = 'encryption_backfill_completed_version' LIMIT 1"
    )
    return false if raw_value.nil?

    # safe_load, not unsafe_load/load: raw_value comes from a raw SQL read of
    # a DB row (see comment above - this deliberately bypasses the Setting
    # model), so it must be treated as untrusted input. unsafe_load can
    # instantiate arbitrary Ruby objects from crafted YAML (CWE-502); anyone
    # who can write to this row (compromised DB credentials, SQLi elsewhere,
    # a bad manual edit) could otherwise get code execution at boot. The
    # value is always a plain serialized Integer, which Psych's default
    # safe_load permitted classes (Numeric, String, ...) already cover -
    # no permitted_classes/aliases expansion needed.
    stored_version = YAML.safe_load(raw_value)
    return false unless stored_version.is_a?(Integer)

    stored_version >= required_version
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid, Psych::Exception => e
    Rails.logger.warn("[ActiveRecordEncryptionConfig] Could not read encryption backfill status (#{e.class}); defaulting to fallback-enabled") if defined?(Rails.logger) && Rails.logger
    false
  end
end
