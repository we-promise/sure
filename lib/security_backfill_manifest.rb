# frozen_string_literal: true

# Every encrypted attribute that security:backfill_encryption re-encrypts,
# by model name. Session is listed separately because its backfill also
# hashes ip_address. test/lib/security_backfill_manifest_test.rb checks this
# list against each model's `encrypts` declarations, so a newly encrypted
# column fails CI until it is added here.
module SecurityBackfillManifest
  # otp_backup_codes is not here: it is a PostgreSQL array column, which
  # Active Record encryption does not support.
  FIELDS = {
    "User" => %i[otp_secret email unconfirmed_email first_name last_name],
    "Invitation" => %i[token email],
    "InviteCode" => %i[token],
    "MobileDevice" => %i[device_id],
    "PlaidItem" => %i[access_token raw_payload raw_institution_payload],
    "SimplefinItem" => %i[access_url raw_payload raw_institution_payload],
    "LunchflowItem" => %i[api_key raw_payload raw_institution_payload],
    "EnableBankingItem" => %i[client_certificate session_id raw_payload raw_institution_payload last_psu_ip],
    "AkahuItem" => %i[app_token user_token raw_payload raw_institution_payload],
    "BinanceItem" => %i[api_key api_secret raw_payload],
    "BrexItem" => %i[token raw_payload raw_institution_payload],
    "CoinbaseItem" => %i[api_key api_secret raw_payload raw_institution_payload],
    "CoinspotItem" => %i[api_key api_secret raw_payload],
    "CoinstatsItem" => %i[api_key raw_payload raw_institution_payload],
    "FioItem" => %i[token raw_payload raw_institution_payload],
    "IbkrItem" => %i[query_id token raw_payload],
    "IndexaCapitalItem" => %i[password api_token username document raw_payload raw_institution_payload],
    "KrakenItem" => %i[api_key api_secret raw_payload],
    "MercuryItem" => %i[token raw_payload raw_institution_payload],
    "MonobankItem" => %i[access_token raw_payload raw_institution_payload],
    "OnchainWalletItem" => %i[etherscan_api_key],
    "QuestradeItem" => %i[refresh_token raw_payload raw_institution_payload],
    "RedbarkItem" => %i[api_key raw_payload raw_institution_payload],
    "SharesightItem" => %i[client_id client_secret],
    "SnaptradeItem" => %i[client_id consumer_key snaptrade_user_secret oauth_access_token oauth_refresh_token raw_payload raw_institution_payload],
    "SophtronItem" => %i[user_id access_key raw_payload raw_institution_payload raw_customer_payload raw_job_payload],
    "TradeRepublicItem" => %i[phone_number session_blob pending_login_state],
    "Trading212Item" => %i[api_key api_secret raw_instruments_payload],
    "TruelayerItem" => %i[client_secret access_token refresh_token raw_payload raw_institution_payload],
    "UpItem" => %i[access_token raw_payload raw_institution_payload],
    "WiseItem" => %i[token raw_payload sca_private_key],
    "PlaidAccount" => %i[raw_payload raw_transactions_payload raw_holdings_payload raw_liabilities_payload],
    "SimplefinAccount" => %i[raw_payload raw_transactions_payload raw_holdings_payload],
    "LunchflowAccount" => %i[raw_payload raw_transactions_payload raw_holdings_payload],
    "EnableBankingAccount" => %i[raw_payload raw_transactions_payload],
    "TruelayerAccount" => %i[raw_payload raw_transactions_payload],
    "SnaptradeAccount" => %i[raw_payload raw_transactions_payload raw_holdings_payload raw_activities_payload account_number raw_balances_payload],
    "CoinbaseAccount" => %i[raw_payload raw_transactions_payload],
    "CoinspotAccount" => %i[raw_payload raw_transactions_payload],
    "CoinstatsAccount" => %i[raw_payload raw_transactions_payload],
    "FioAccount" => %i[raw_payload raw_transactions_payload iban],
    "MercuryAccount" => %i[raw_payload raw_transactions_payload],
    "MonobankAccount" => %i[raw_payload raw_transactions_payload],
    "AkahuAccount" => %i[raw_payload raw_transactions_payload formatted_account],
    "BinanceAccount" => %i[raw_payload raw_transactions_payload],
    "BrexAccount" => %i[raw_payload raw_transactions_payload],
    "IbkrAccount" => %i[raw_holdings_payload raw_activities_payload raw_cash_report_payload raw_equity_summary_payload],
    "IndexaCapitalAccount" => %i[raw_payload raw_holdings_payload raw_activities_payload],
    "KrakenAccount" => %i[raw_payload raw_transactions_payload],
    "OnchainWalletAccount" => %i[raw_payload raw_movements_payload],
    "QuestradeAccount" => %i[raw_payload raw_holdings_payload raw_activities_payload raw_balances_payload],
    "RedbarkAccount" => %i[raw_payload raw_transactions_payload raw_account_details_payload],
    "SharesightAccount" => %i[raw_payload raw_holdings_payload raw_trades_payload raw_payouts_payload raw_cash_transactions_payload],
    "SophtronAccount" => %i[raw_payload raw_transactions_payload],
    "TradeRepublicAccount" => %i[raw_positions_payload raw_timeline_payload],
    "Trading212Account" => %i[raw_positions_payload raw_orders_payload raw_dividends_payload raw_transactions_payload],
    "UpAccount" => %i[raw_payload raw_transactions_payload],
    "WiseAccount" => %i[raw_payload raw_transactions_payload],
    "ApiKey" => %i[display_key],
    "SsoProvider" => %i[client_secret],
    "SsoIdentityBlock" => %i[identity_label],
    "SecurityAuditLog" => %i[user_email ip_address user_agent]
  }.freeze

  HANDLED_SEPARATELY = %w[Session].freeze

  # Framework models whose encryption Sure does not configure.
  IGNORED = %w[ActionText::EncryptedRichText].freeze

  module_function

  def each_model
    FIELDS.each { |model_name, fields| yield model_name.constantize, fields }
  end
end
