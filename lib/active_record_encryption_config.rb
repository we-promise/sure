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

  # Set only for the one-off commands of a key rotation (see the Docker
  # hosting guide): the SECRET_KEY_BASE whose derived keys encrypted the
  # existing data, so it still decrypts while the backfill moves it to the
  # current keys.
  PREVIOUS_SECRET_KEY_BASE_ENV = "ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE"

  # Previous-scheme key provider for keys derived from an old
  # SECRET_KEY_BASE. Rails derives every scheme's keys with the globally
  # configured salt, so the old salt needs a provider of its own. Keys are
  # derived on first use, once Rails has settled hash_digest_class.
  class DerivedKeyProvider
    def initialize(password, salt)
      @password = password
      @salt = salt
    end

    def encryption_key
      @encryption_key ||= begin
        config = ActiveRecord::Encryption.config
        secret = ActiveSupport::KeyGenerator.new(@password, hash_digest_class: config.hash_digest_class)
          .generate_key(@salt, ActiveRecord::Encryption.cipher.key_length)
        ActiveRecord::Encryption::Key.new(secret)
      end
    end

    def decryption_keys(_encrypted_message)
      [ encryption_key ]
    end
  end

  CONFIG_KEYS = %i[
    primary_key
    deterministic_key
    key_derivation_salt
  ].freeze

  # Single source of truth for which models/fields security:backfill_encryption
  # covers, keyed by the same symbol the task's `results` hash uses. Model
  # names are strings (not bare constants) and resolved via constantize only
  # from the task itself (after full Rails boot, via its :environment
  # dependency) - this file is `require`d from config/initializers/
  # active_record_encryption.rb, before autoloading is available, so a bare
  # constant reference here would raise NameError at boot.
  #
  # test/lib/tasks/security_backfill_test.rb asserts this stays in exact sync
  # with each model's real `encrypts` declarations and that every model that
  # declares `encrypts` appears here, so a newly encrypted column fails CI
  # until it is listed. Session is deliberately excluded: its backfill
  # (lib/tasks/security_backfill.rake#backfill_sessions) also hashes
  # ip_address into ip_address_digest, which isn't a 1:1 encrypted copy of an
  # existing field the way every entry below is. otp_backup_codes is not
  # listed: it is a PostgreSQL array column, which Active Record encryption
  # does not support.
  BACKFILL_MANIFEST = {
    users: [ "User", %i[otp_secret email unconfirmed_email first_name last_name] ],
    invitations: [ "Invitation", %i[token email] ],
    invite_codes: [ "InviteCode", %i[token] ],
    mobile_devices: [ "MobileDevice", %i[device_id] ],
    plaid_items: [ "PlaidItem", %i[access_token raw_payload raw_institution_payload] ],
    simplefin_items: [ "SimplefinItem", %i[access_url raw_payload raw_institution_payload] ],
    lunchflow_items: [ "LunchflowItem", %i[api_key raw_payload raw_institution_payload] ],
    enable_banking_items: [ "EnableBankingItem", %i[client_certificate session_id raw_payload raw_institution_payload last_psu_ip] ],
    truelayer_items: [ "TruelayerItem", %i[client_secret access_token refresh_token raw_payload raw_institution_payload] ],
    fio_items: [ "FioItem", %i[token raw_payload raw_institution_payload] ],
    akahu_items: [ "AkahuItem", %i[app_token user_token raw_payload raw_institution_payload] ],
    binance_items: [ "BinanceItem", %i[api_key api_secret raw_payload] ],
    brex_items: [ "BrexItem", %i[token raw_payload raw_institution_payload] ],
    coinbase_items: [ "CoinbaseItem", %i[api_key api_secret raw_payload raw_institution_payload] ],
    coinspot_items: [ "CoinspotItem", %i[api_key api_secret raw_payload] ],
    coinstats_items: [ "CoinstatsItem", %i[api_key raw_payload raw_institution_payload] ],
    ibkr_items: [ "IbkrItem", %i[query_id token raw_payload] ],
    indexa_capital_items: [ "IndexaCapitalItem", %i[password api_token username document raw_payload raw_institution_payload] ],
    kraken_items: [ "KrakenItem", %i[api_key api_secret raw_payload] ],
    mercury_items: [ "MercuryItem", %i[token raw_payload raw_institution_payload] ],
    monobank_items: [ "MonobankItem", %i[access_token raw_payload raw_institution_payload] ],
    onchain_wallet_items: [ "OnchainWalletItem", %i[etherscan_api_key] ],
    questrade_items: [ "QuestradeItem", %i[refresh_token raw_payload raw_institution_payload] ],
    redbark_items: [ "RedbarkItem", %i[api_key raw_payload raw_institution_payload] ],
    snaptrade_items: [ "SnaptradeItem", %i[client_id consumer_key snaptrade_user_secret oauth_access_token oauth_refresh_token raw_payload raw_institution_payload] ],
    sharesight_items: [ "SharesightItem", %i[client_id client_secret] ],
    sophtron_items: [ "SophtronItem", %i[user_id access_key raw_payload raw_institution_payload raw_customer_payload raw_job_payload] ],
    trade_republic_items: [ "TradeRepublicItem", %i[phone_number session_blob pending_login_state] ],
    trading212_items: [ "Trading212Item", %i[api_key api_secret raw_instruments_payload] ],
    up_items: [ "UpItem", %i[access_token raw_payload raw_institution_payload] ],
    wise_items: [ "WiseItem", %i[token raw_payload sca_private_key] ],
    plaid_accounts: [ "PlaidAccount", %i[raw_payload raw_transactions_payload raw_holdings_payload raw_liabilities_payload] ],
    simplefin_accounts: [ "SimplefinAccount", %i[raw_payload raw_transactions_payload raw_holdings_payload] ],
    lunchflow_accounts: [ "LunchflowAccount", %i[raw_payload raw_transactions_payload raw_holdings_payload] ],
    enable_banking_accounts: [ "EnableBankingAccount", %i[raw_payload raw_transactions_payload] ],
    truelayer_accounts: [ "TruelayerAccount", %i[raw_payload raw_transactions_payload] ],
    fio_accounts: [ "FioAccount", %i[raw_payload raw_transactions_payload iban] ],
    snaptrade_accounts: [ "SnaptradeAccount", %i[raw_payload raw_transactions_payload raw_holdings_payload raw_activities_payload raw_balances_payload account_number] ],
    coinbase_accounts: [ "CoinbaseAccount", %i[raw_payload raw_transactions_payload] ],
    coinspot_accounts: [ "CoinspotAccount", %i[raw_payload raw_transactions_payload] ],
    coinstats_accounts: [ "CoinstatsAccount", %i[raw_payload raw_transactions_payload] ],
    mercury_accounts: [ "MercuryAccount", %i[raw_payload raw_transactions_payload] ],
    monobank_accounts: [ "MonobankAccount", %i[raw_payload raw_transactions_payload] ],
    akahu_accounts: [ "AkahuAccount", %i[raw_payload raw_transactions_payload formatted_account] ],
    binance_accounts: [ "BinanceAccount", %i[raw_payload raw_transactions_payload] ],
    brex_accounts: [ "BrexAccount", %i[raw_payload raw_transactions_payload] ],
    ibkr_accounts: [ "IbkrAccount", %i[raw_holdings_payload raw_activities_payload raw_cash_report_payload raw_equity_summary_payload] ],
    indexa_capital_accounts: [ "IndexaCapitalAccount", %i[raw_payload raw_holdings_payload raw_activities_payload] ],
    kraken_accounts: [ "KrakenAccount", %i[raw_payload raw_transactions_payload] ],
    onchain_wallet_accounts: [ "OnchainWalletAccount", %i[raw_payload raw_movements_payload] ],
    questrade_accounts: [ "QuestradeAccount", %i[raw_payload raw_holdings_payload raw_activities_payload raw_balances_payload] ],
    redbark_accounts: [ "RedbarkAccount", %i[raw_payload raw_transactions_payload raw_account_details_payload] ],
    sharesight_accounts: [ "SharesightAccount", %i[raw_payload raw_holdings_payload raw_trades_payload raw_payouts_payload raw_cash_transactions_payload] ],
    sophtron_accounts: [ "SophtronAccount", %i[raw_payload raw_transactions_payload] ],
    trade_republic_accounts: [ "TradeRepublicAccount", %i[raw_positions_payload raw_timeline_payload] ],
    trading212_accounts: [ "Trading212Account", %i[raw_positions_payload raw_orders_payload raw_dividends_payload raw_transactions_payload] ],
    up_accounts: [ "UpAccount", %i[raw_payload raw_transactions_payload] ],
    wise_accounts: [ "WiseAccount", %i[raw_payload raw_transactions_payload] ],
    api_keys: [ "ApiKey", %i[display_key] ],
    sso_providers: [ "SsoProvider", %i[client_secret] ],
    sso_identity_blocks: [ "SsoIdentityBlock", %i[identity_label] ],
    security_audit_logs: [ "SecurityAuditLog", %i[user_email ip_address user_agent] ]
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
    credentials.active_record_encryption.present?
  rescue NoMethodError
    false
  end

  def runtime_configured?(config = Rails.application.config.active_record.encryption)
    CONFIG_KEYS.all? { |key| config.public_send(key).present? }
  rescue NoMethodError
    false
  end

  def explicitly_configured?
    complete_env? || credentials_configured?
  end

  def ready?
    explicitly_configured? || runtime_configured?
  end

  # Only meaningful for the auto-derived path: explicit env vars or Rails
  # credentials (explicitly_configured?) take precedence over SECRET_KEY_BASE
  # in config/initializers/active_record_encryption.rb, so an install that
  # set its own encryption keys but happens to still have this SECRET_KEY_BASE
  # value (e.g. never bothered rotating it because it isn't the key source)
  # is not actually affected and should not be warned.
  def using_known_compromised_secret_key_base?(secret_key_base = Rails.application.secret_key_base)
    return false if explicitly_configured?

    KNOWN_COMPROMISED_SECRET_KEY_BASES.include?(secret_key_base)
  rescue NoMethodError
    false
  end

  # The keys config/initializers/active_record_encryption.rb derives from
  # SECRET_KEY_BASE when no explicit keys are configured.
  def derived_keys(secret_key_base)
    CONFIG_KEYS.to_h do |key|
      [ key, Digest::SHA256.hexdigest("#{secret_key_base}:#{key}")[0..63] ]
    end
  end

  # Previous schemes for `config.active_record.encryption.previous`, built
  # from the keys derived from PREVIOUS_SECRET_KEY_BASE_ENV. Rails applies a
  # global previous scheme only to attributes with the same determinism, so
  # there is one scheme for each kind.
  def previous_schemes(env = ENV)
    old_base = env[PREVIOUS_SECRET_KEY_BASE_ENV]
    return [] if old_base.blank?

    keys = derived_keys(old_base)
    [
      { key_provider: DerivedKeyProvider.new(keys[:primary_key], keys[:key_derivation_salt]) },
      { deterministic: true, key_provider: DerivedKeyProvider.new(keys[:deterministic_key], keys[:key_derivation_salt]) }
    ]
  end

  def env_value_present?(env, key)
    env[key].present?
  end
end
